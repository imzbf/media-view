const { createHash } = require('node:crypto');
const { readdir, readFile } = require('node:fs/promises');
const { join } = require('node:path');

const installNote = '选择对应的 DMG（Apple Silicon：arm64，Intel：x86_64），打开后将 MediaView 拖入 Applications。应用仅使用 ad-hoc 签名，未经 Developer ID 签名或 Apple 公证，macOS 首次打开时可能显示安全提示。';
const checksumHeading = '### SHA-256';

function stableVersion({ eventName, ref, payload }) {
    let tag;
    if (eventName === 'workflow_dispatch') {
        tag = payload.inputs?.tag;
    } else {
        if (eventName !== 'push' || payload.ref !== ref || payload.created !== true ||
            payload.deleted !== false || payload.forced !== false || !ref.startsWith('refs/tags/')) return '';
        tag = ref.slice('refs/tags/'.length);
    }
    return /^v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))$/.exec(tag ?? '')?.[1] ?? '';
}

async function resolveReleaseTarget({ github, context, commit }) {
    const version = stableVersion(context);
    if (!version) throw new Error('Expected a new stable tag push or a manual release with an existing vX.Y.Z tag.');
    const tag = `v${version}`;
    // 补发使用标签原有提交，不能把运行工作流所选分支的新代码悄悄打进旧版本。
    // getCommit 会将附注标签解析到提交，后续所有 job 都使用这份固定 SHA。
    const { data } = await github.rest.repos.getCommit({ ...context.repo, ref: `tags/${tag}` });
    if (context.eventName === 'push' && data.sha !== commit) {
        throw new Error(`${tag} no longer points to the triggering commit ${commit}.`);
    }
    return { version, tag, commit: data.sha };
}

function checksumLine({ name, digest }) {
    return `${digest.slice('sha256:'.length)}  ${name}`;
}

function matches(asset, file) {
    return asset?.state === 'uploaded' && asset.size === file.data.length && asset.digest === file.digest;
}

async function publishRelease({ github, context, commit, directory }) {
    const version = stableVersion(context);
    if (!version) throw new Error('Expected a stable release tag from a new push or a manual release.');
    const tag = `v${version}`;
    const names = ['arm64', 'x86_64'].map(arch => `MediaView-${version}-${arch}.dmg`);
    const entries = await readdir(directory, { withFileTypes: true });
    if (entries.length !== names.length || entries.some(e => !e.isFile() || !names.includes(e.name))) {
        throw new Error(`Expected exactly these build artifacts: ${names.join(', ')}`);
    }
    const files = await Promise.all(names.map(async name => {
        const data = await readFile(join(directory, name));
        if (!data.length) throw new Error(`Empty artifact: ${name}`);
        return { name, data, digest: `sha256:${createHash('sha256').update(data).digest('hex')}` };
    }));

    const repo = context.repo;
    const api = github.rest.repos;
    async function checkTag() {
        // 将远端标签（含附注标签）解析到提交；不替被删除或移动的标签发布。
        const { data } = await api.getCommit({ ...repo, ref: `tags/${tag}` });
        if (data.sha !== commit) throw new Error(`${tag} no longer points to the tested commit ${commit}.`);
    }
    await checkTag();
    // 以有写权限的身份分页列出 Release，才能发现上一次运行留下的草稿。
    const releases = (await github.paginate(api.listReleases, { ...repo, per_page: 100 }))
        .filter(release => release.tag_name === tag);
    if (releases.length > 1) throw new Error(`Multiple releases for ${tag}; inspect them manually.`);
    const release = releases[0] ?? (await api.createRelease({
        ...repo, tag_name: tag, target_commitish: commit, name: `MediaView ${tag}`,
        draft: true, prerelease: false, body: installNote,
    })).data;
    const params = { ...repo, release_id: release.id };
    const listAssets = () => github.paginate(api.listReleaseAssets, { ...params, per_page: 100 });
    async function checkDraft() {
        const { data } = await api.getRelease(params);
        if (!data.draft || data.tag_name !== tag || data.prerelease) throw new Error(`Release ${tag} is no longer the expected draft.`);
        return data;
    }

    const assets = await listAssets();
    if (release.prerelease || assets.some(a => !names.includes(a.name)) || new Set(assets.map(a => a.name)).size !== assets.length) {
        throw new Error(`Unexpected release type or assets on ${tag}; refusing to modify it.`);
    }
    if (!release.draft) {
        // 重建会改变镜像元数据，优先核对首次发布记录的摘要；没有记录时只接受与本次产物相同的附件。
        const lines = (release.body ?? '').split(/\r?\n/);
        const hasChecksums = lines.includes(checksumHeading);
        const complete = files.every(file => {
            const asset = assets.find(a => a.name === file.name);
            return hasChecksums ? asset?.state === 'uploaded' && asset.size > 0 &&
                /^sha256:[a-f0-9]{64}$/.test(asset.digest) && lines.includes(checksumLine(asset)) : matches(asset, file);
        });
        if (!complete) throw new Error(`Inconsistent public release ${tag}; no public assets were changed.`);
        return `Public release ${tag} is complete; left unchanged.`;
    }

    for (const file of files) {
        const previous = assets.find(a => a.name === file.name);
        if (matches(previous, file)) continue;
        // 中断会留下零字节的 starter，重建也可能生成不同的镜像；仅替换草稿中不匹配的同名附件。
        if (previous) {
            await checkDraft();
            await api.deleteReleaseAsset({ ...repo, asset_id: previous.id });
        }
        await checkDraft();
        await api.uploadReleaseAsset({ ...params, name: file.name, data: file.data,
            headers: { 'content-type': 'application/x-apple-diskimage', 'content-length': file.data.length },
        });
    }

    const uploaded = await listAssets();
    if (uploaded.length !== files.length || !files.every(f => matches(uploaded.find(a => a.name === f.name), f))) {
        throw new Error(`Draft ${tag} failed asset verification; not publishing.`);
    }
    await checkTag();
    const draft = await checkDraft();
    const notes = draft.body?.includes(installNote) ? draft.body : [draft.body, installNote].filter(Boolean).join('\n\n');
    const body = `${notes}\n\n${checksumHeading}\n\n\`\`\`text\n${files.map(checksumLine).join('\n')}\n\`\`\``;
    await api.updateRelease({ ...params, draft: false, prerelease: false, body });
    return `Published ${tag}: ${names.join(', ')}`;
}

module.exports = { stableVersion, resolveReleaseTarget, publishRelease };
