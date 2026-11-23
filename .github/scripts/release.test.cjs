const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { mkdir, mkdtemp, rm, writeFile } = require('node:fs/promises');
const { join } = require('node:path');
const test = require('node:test');
const { stableVersion, resolveReleaseTarget, publishRelease } = require('./release.cjs');

const tag = 'v1.2.3';
const commit = 'a'.repeat(40);
const [arm, intel] = ['arm64', 'x86_64'].map(arch => `MediaView-1.2.3-${arch}.dmg`);
function push(ref = `refs/tags/${tag}`, event = {}) {
    return { eventName: 'push', repo: { owner: 'example', repo: 'media-view' }, ref,
        payload: { ref, created: true, deleted: false, forced: false, ...event } };
}

function manual(tagName = tag) {
    return { eventName: 'workflow_dispatch', repo: { owner: 'example', repo: 'media-view' },
        ref: 'refs/heads/main', payload: { inputs: { tag: tagName } } };
}

test('only a new, stable tag push selects a version', () => {
    for (const version of ['0.0.0', '1.2.3', '12.34.100']) {
        assert.equal(stableVersion(push(`refs/tags/v${version}`)), version);
    }
    for (const name of ['1.2.3', 'v1.2', 'v01.2.3', 'v1.2.03', 'v1.2.3-rc.1', 'v1.2.3+1', 'v1.2.3.4']) {
        assert.equal(stableVersion(push(`refs/tags/${name}`)), '');
    }
    for (const event of [{ created: false }, { deleted: true }, { forced: true }, { ref: 'refs/heads/main' }]) {
        assert.equal(stableVersion(push(undefined, event)), '');
    }
    assert.equal(stableVersion(push(`refs/heads/${tag}`)), '');
    for (const eventName of ['workflow_dispatch', 'pull_request']) {
        assert.equal(stableVersion({ ...push(), eventName }), '');
    }
});

test('manual releases require an explicit stable tag instead of the selected workflow branch', () => {
    assert.equal(stableVersion(manual('v1.0.0')), '1.0.0');
    assert.equal(stableVersion(manual('v12.34.100')), '12.34.100');
    for (const name of ['', 'main', 'refs/tags/v1.0.0', 'v01.0.0', 'v1.0', 'v1.0.0-rc.1', 'v1.0.0+1']) {
        assert.equal(stableVersion(manual(name)), '');
    }
});

async function fixture(t, context = push()) {
    const root = join(__dirname, '../../.build');
    await mkdir(root, { recursive: true });
    const dir = await mkdtemp(join(root, 'release-test.'));
    t.after(() => rm(dir, { recursive: true, force: true }));
    for (const name of [arm, intel]) await writeFile(join(dir, name), `disk image: ${name}`);

    const state = { release: null, assets: [], writes: [], sha: commit };
    let nextId = 1;
    const api = {
        getCommit({ ref }) { assert.equal(ref, `tags/${tag}`); return { data: { sha: state.sha } }; },
        listReleases() { return state.release ? [{ ...state.release }] : []; },
        listReleaseAssets() { return state.assets.map(a => ({ ...a })); },
        getRelease() { return { data: { ...state.release } }; },
        createRelease(params) {
            assert.equal(state.release, null);
            assert.equal(params.draft, true);
            assert.equal(params.target_commitish, commit);
            state.release = { id: 10, ...params };
            state.writes.push('draft');
            return { data: { ...state.release } };
        },
        uploadReleaseAsset({ name, data }) {
            assert.equal(state.release.draft, true);
            assert.ok(!state.assets.some(a => a.name === name));
            state.writes.push(`upload ${name}`);
            state.assets.push({ name, id: nextId++, size: data.length, state: 'uploaded',
                digest: `sha256:${createHash('sha256').update(data).digest('hex')}` });
        },
        deleteReleaseAsset({ asset_id }) {
            assert.equal(state.release.draft, true);
            const index = state.assets.findIndex(a => a.id === asset_id);
            assert.notEqual(index, -1);
            state.writes.push(`delete ${state.assets[index].name}`);
            state.assets.splice(index, 1);
        },
        updateRelease(params) {
            assert.equal(state.release.draft, true);
            state.writes.push('publish');
            Object.assign(state.release, params);
        },
    };
    const github = { rest: { repos: api }, paginate: (method, params) => method(params) };
    return { dir, state, api, github, run: () => publishRelease({ github, context, commit, directory: dir }) };
}

test('manual recovery pins the existing tag even when workflow code has a newer commit', async t => {
    const { github } = await fixture(t);
    const target = await resolveReleaseTarget({ github, context: manual(), commit: 'b'.repeat(40) });
    assert.deepEqual(target, { version: '1.2.3', tag, commit });
});

test('release resolution rejects invalid or missing tags and moved push targets', async t => {
    const { github, state, api } = await fixture(t);
    await assert.rejects(resolveReleaseTarget({ github, context: manual('main'), commit }), /stable tag/);
    state.sha = 'b'.repeat(40);
    await assert.rejects(resolveReleaseTarget({ github, context: push(), commit }), /triggering commit/);
    api.getCommit = () => { throw new Error('Tag not found'); };
    await assert.rejects(resolveReleaseTarget({ github, context: manual(), commit }), /Tag not found/);
    assert.deepEqual(state.writes, []);
});

test('publishes two verified DMGs with installation and signing notes', async t => {
    const { run, state } = await fixture(t);
    await run();
    assert.deepEqual(state.writes, ['draft', `upload ${arm}`, `upload ${intel}`, 'publish']);
    assert.equal(state.release.draft, false);
    assert.equal(state.release.prerelease, false);
    assert.match(state.release.body, /ad-hoc.*Apple 公证.*首次打开/);
    for (const { digest, name } of state.assets) assert.ok(state.release.body.includes(`${digest.slice(7)}  ${name}`));
});

test('manual recovery publishes the verified tag and keeps existing public releases unchanged', async t => {
    const { run, state } = await fixture(t, manual());
    await run();
    assert.equal(state.release.tag_name, tag);
    assert.equal(state.release.target_commitish, commit);
    assert.equal(state.release.draft, false);
    state.writes.length = 0;
    await run();
    assert.deepEqual(state.writes, []);
});

test('moving a tag during manual recovery prevents publication', async t => {
    const { run, state, api } = await fixture(t, manual());
    const getCommit = api.getCommit;
    api.getCommit = params => {
        if (state.assets.length) state.sha = 'b'.repeat(40);
        return getCommit(params);
    };
    await assert.rejects(run(), /no longer points/);
    assert.equal(state.release.draft, true);
    assert.ok(!state.writes.includes('publish'));
});

test('missing, empty or extra local artifacts cannot create a release', async t => {
    const { run, state, dir } = await fixture(t);
    await rm(join(dir, intel));
    await assert.rejects(run, /Expected exactly/);
    await writeFile(join(dir, intel), '');
    await assert.rejects(run, /Empty artifact/);
    await writeFile(join(dir, 'MediaView.zip'), 'zip');
    await assert.rejects(run, /Expected exactly/);
    assert.deepEqual(state.writes, []);
});

test('resumes an interrupted draft, replacing only the failed upload', async t => {
    const { run, state, api } = await fixture(t);
    const upload = api.uploadReleaseAsset;
    api.uploadReleaseAsset = params => {
        if (params.name !== intel) return upload(params);
        state.assets.push({ id: 50, name: intel, state: 'starter', size: 0, digest: null });
        throw new Error('upload interrupted');
    };
    await assert.rejects(run, /upload interrupted/);
    assert.equal(state.release.draft, true);
    state.release.body = 'Existing draft notes';
    state.writes.length = 0;
    api.uploadReleaseAsset = upload;
    await run();
    assert.deepEqual(state.writes, [`delete ${intel}`, `upload ${intel}`, 'publish']);
    assert.ok(state.release.body.startsWith('Existing draft notes'));
});

test('bad remote digest prevents publication; retry repairs that draft asset', async t => {
    const { run, state, api } = await fixture(t);
    const upload = api.uploadReleaseAsset;
    api.uploadReleaseAsset = params => {
        upload(params);
        if (params.name === arm) state.assets[0].digest = `sha256:${'0'.repeat(64)}`;
    };
    await assert.rejects(run, /failed asset verification/);
    assert.equal(state.release.draft, true);
    api.uploadReleaseAsset = upload;
    state.writes.length = 0;
    await run();
    assert.deepEqual(state.writes, [`delete ${arm}`, `upload ${arm}`, 'publish']);
});

test('a complete public release is read-only even when a rebuild yields different bytes', async t => {
    const { run, state, dir } = await fixture(t);
    await run();
    state.writes.length = 0;
    await writeFile(join(dir, arm), 'rebuilt image');
    assert.match(await run(), /left unchanged/);
    assert.deepEqual(state.writes, []);
});

test('a public release without recorded checksums must match both verified artifacts', async t => {
    const { run, state, dir } = await fixture(t);
    await run();
    state.release.body = 'Earlier release';
    state.writes.length = 0;
    assert.match(await run(), /left unchanged/);
    await writeFile(join(dir, intel), 'other bytes');
    await assert.rejects(run, /Inconsistent public release/);
    assert.deepEqual(state.writes, []);
});

test('missing, changed, incomplete or unexpected public assets fail without writes', async t => {
    const { run, state } = await fixture(t);
    await run();
    state.writes.length = 0;
    const [a, b] = state.assets;
    for (const assets of [[a], [a, { ...b, digest: a.digest }], [a, { ...b, state: 'starter' }],
        [a, b, { name: 'extra.zip' }]]) {
        state.assets = assets;
        await assert.rejects(run, /Inconsistent public release|Unexpected release/);
        assert.deepEqual(state.writes, []);
    }
});

test('a moved or deleted tag cannot create a release or make a draft public', async t => {
    const { run, state, api } = await fixture(t);
    state.sha = 'b'.repeat(40);
    await assert.rejects(run, /no longer points/);
    assert.deepEqual(state.writes, []);
    state.sha = commit;
    const getCommit = api.getCommit;
    api.getCommit = params => {
        if (state.assets.length) throw new Error('Tag not found');
        return getCommit(params);
    };
    await assert.rejects(run, /Tag not found/);
    assert.equal(state.release.draft, true);
    assert.ok(!state.writes.includes('publish'));
});
