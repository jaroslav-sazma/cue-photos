import Api from '../../third_party/gptk/src/api/api';
import type { AlbumsPage, AlbumItemsPage, BulkMediaInfo, LibraryTimelinePage, TrashPage } from '../../third_party/gptk/src/types';

// Raw page-wise calls only: the native side drives paging, chunking and cancellation,
// so every bridge call is a single RPC with a real error path. gptk's ApiUtils bulk
// helpers are deliberately not bundled — they swallow chunk errors and return partial
// data as success.
const api = new Api();

// Captured from a real photos.google.com rename request by the owner, 2026-10-31:
// f.req [["SVP9Xd","[\"<albumMediaKey>\",\"<newTitle>\"]",null,"generic"]]
const RENAME_ALBUM_RPCID = 'SVP9Xd';

// Shared albums refuse SVP9Xd; their rename is a different RPC with the key wrapped
// in an array. Captured from a real photos.google.com rename of a shared album by
// the owner, 2026-11-01:
// f.req [["uF3Orb","[[\"<albumMediaKey>\"],\"<newTitle>\"]",null,"generic"]]
const RENAME_SHARED_ALBUM_RPCID = 'uF3Orb';

// Sharing converts the album to a shared one (it gets a NEW mediaKey) and sends the
// e-mail invites, all in this single RPC. Captured from a real photos.google.com
// share-with-user request by the owner, 2026-11-01:
// f.req [["SFKp8c","[null,null,<options>,[1,[[\"<albumMediaKey>\"],[1,2,3]],null,null,null,null,[1]],null,[null,[[5,\"<email>\",[\"<email>\"],2]]],null,null,[1,2,3,5,6]]",null,"generic"]]
// The web client fires three follow-ups (UJlKrf/snAcKc reload, wGF44d, CkpYK) that
// only sync its own UI state; the native side refreshes the album list instead.
const SHARE_ALBUM_RPCID = 'SFKp8c';

// What the bridge world actually sees — logged on the native side when a call fails,
// so an opaque "Failed to fetch" can still be diagnosed (missing session fields, wrong
// origin, unseeded WIZ_global_data).
function diag(): Record<string, unknown> {
  const w = window as unknown as { location?: Location; WIZ_global_data?: Record<string, unknown> };
  const g = w.WIZ_global_data ?? {};
  return {
    href: w.location?.href ?? null,
    pathname: w.location?.pathname ?? null,
    hasWiz: typeof w.WIZ_global_data !== 'undefined',
    atLength: typeof g.SNlM0e === 'string' ? (g.SNlM0e as string).length : null,
    hasFsid: typeof g.FdrFJe === 'string',
    hasBl: typeof g.cfb2h === 'string',
    path: typeof g.eptZe === 'string' ? g.eptZe : null,
  };
}

// Two mutations bypass gptk's makeApiRequest, both built single-shot here and
// mirroring gptk's envelope and response handling. Each is only served in the
// context of its originating page — a source-path of /share/<key> (LjmOue) or
// /album/<key> (SFKp8c), the soc-app parameters and the page's hl locale, with
// no pageId — which gptk's client cannot express (owner captures, 2026-11-01:
// payloads byte-identical, only these URL parameters differ; the server answers
// error 8 without them). SFKp8c also benefits from the single shot: gptk would
// retry internally, which could mail duplicate invitations.
async function singleShotApiRequest(rpcid: string, requestData: unknown, contextSourcePath?: string): Promise<void> {
  const w = window as unknown as { WIZ_global_data?: Record<string, unknown>; document?: { documentElement?: { lang?: string } } };
  const g = w.WIZ_global_data ?? {};
  const str = (key: string): string => (typeof g[key] === 'string' ? (g[key] as string) : '');
  // without a page context the request stays byte-compatible with gptk's
  // (parameters, order and headers) — the only difference is the single shot
  const params = new URLSearchParams({
    rpcids: rpcid,
    'source-path': contextSourcePath ?? window.location?.pathname ?? '/',
    'f.sid': str('FdrFJe'),
    bl: str('cfb2h'),
  });
  if (contextSourcePath) {
    params.set('hl', w.document?.documentElement?.lang || 'en');
    params.set('soc-app', '165');
    params.set('soc-platform', '1');
    params.set('soc-device', '1');
    params.set('_reqid', String(Math.floor(100000 + Math.random() * 900000)));
  } else {
    params.set('pageId', 'none');
  }
  params.set('rt', 'c');
  const wrapped = [[[rpcid, JSON.stringify(requestData), null, 'generic']]];
  const body = `f.req=${encodeURIComponent(JSON.stringify(wrapped))}&at=${encodeURIComponent(str('SNlM0e'))}&`;
  const path = str('eptZe') || '/_/PhotosUi/';
  const headers: Record<string, string> = { 'content-type': 'application/x-www-form-urlencoded;charset=UTF-8' };
  if (contextSourcePath) headers['x-same-domain'] = '1';
  const response = await fetch(`https://photos.google.com${path}data/batchexecute?${params.toString()}`, {
    method: 'POST',
    headers,
    body,
    credentials: 'include',
    // the page context travels in the Referer too, not just in source-path
    ...(contextSourcePath ? { referrer: `https://photos.google.com${contextSourcePath}` } : {}),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`HTTP ${response.status}; body: ${text.slice(0, 300)}`);
  const line = text.split('\n').find((l) => l.includes('wrb.fr'));
  if (!line) throw new Error(`No wrb.fr envelope in response: ${text.slice(0, 300)}`);
  const parsed = JSON.parse(line);
  // the raw envelope rides along so a refusal shows Google's error code
  if (!parsed?.[0]?.[2]) throw new Error(`${rpcid} returned no payload; envelope: ${line.slice(0, 300)}`);
}

const bridge = {
  ping(): { ok: true } {
    return { ok: true };
  },
  diag,
  async getAlbumsPage(pageId: string | null): Promise<AlbumsPage> {
    return api.getAlbums(pageId);
  },
  async getLibraryPage(fromTimestamp: number | null, pageId: string | null): Promise<LibraryTimelinePage> {
    return api.getItemsByTakenDate(fromTimestamp, null, pageId);
  },
  async getAlbumItemsPage(albumMediaKey: string, pageId: string | null, authKey: string | null): Promise<AlbumItemsPage> {
    return api.getAlbumPage(albumMediaKey, pageId, authKey);
  },
  async createAlbum(name: string): Promise<string> {
    return api.createAlbum(name);
  },
  async addItemsToAlbum(mediaKeys: string[], albumMediaKey: string): Promise<void> {
    await api.addItemsToAlbum(mediaKeys, albumMediaKey);
  },
  async addItemsToSharedAlbum(mediaKeys: string[], albumMediaKey: string): Promise<void> {
    await api.addItemsToSharedAlbum(mediaKeys, albumMediaKey);
  },
  async getTrashPage(pageId: string | null): Promise<TrashPage> {
    return api.getTrashItems(pageId);
  },
  async moveItemsToTrash(dedupKeys: string[]): Promise<void> {
    await api.moveItemsToTrash(dedupKeys);
  },
  async restoreFromTrash(dedupKeys: string[]): Promise<void> {
    await api.restoreFromTrash(dedupKeys);
  },
  async getBatchMediaInfo(mediaKeys: string[]): Promise<BulkMediaInfo[]> {
    return api.getBatchMediaInfo(mediaKeys);
  },
  // both take the album-scoped item mediaKeys an album page returns, not dedupKeys
  async removeItemsFromAlbum(itemMediaKeys: string[]): Promise<void> {
    await api.removeItemsFromAlbum(itemMediaKeys);
  },
  async removeItemsFromSharedAlbum(albumMediaKey: string, itemMediaKeys: string[]): Promise<void> {
    // payload shape per the owner's captures (2026-11-01); the album must be
    // addressed by its share token (the key snAcKc reports) and each item rides
    // in its own wrapper array — [["k1"],["k2"]], not gptk's [["k1","k2"]],
    // which the server rejects with INVALID_ARGUMENT
    await singleShotApiRequest('LjmOue', [
      [albumMediaKey],
      itemMediaKeys.map((key) => [key]),
      [[null, null, null, [null, [], []], null, null, null, null, null, null, null, null, null, []]],
    ], `/share/${albumMediaKey}`);
  },
  async renameAlbum(albumMediaKey: string, newTitle: string, isShared: boolean): Promise<void> {
    const rpcid = isShared ? RENAME_SHARED_ALBUM_RPCID : RENAME_ALBUM_RPCID;
    const payload = isShared ? [[albumMediaKey], newTitle] : [albumMediaKey, newTitle];
    try {
      await api.makeApiRequest(rpcid, payload);
    } catch (e) {
      // mutation RPCs may answer with an empty payload; gptk's client calls that an
      // error even when the rename landed. The native side verifies the new title
      // against a fresh album list, so swallowing this cannot fake a success.
      const message = e instanceof Error ? e.message : String(e);
      if (!message.includes('Missing payload in parsed response')) throw e;
    }
  },
  async shareAlbum(albumMediaKey: string, emails: string[]): Promise<void> {
    // the options block is the web client's default share settings, verbatim from
    // the capture; the response (the new shared mediaKey) is ignored — the native
    // side re-reads the album list, which already carries the new key. Sent in the
    // album's own page context: the server answers error 8 unless source-path is
    // /album/<key> with the hl locale and soc parameters (owner capture,
    // 2026-11-01).
    const options = [null, 1, null, null, 1, null, [[[1, 1], 1], [[1, 2], 1], [[2, 1], 1], [[2, 2], 1], [[3, 1], 0]], null, null, null, null, null, null, [1, 2]];
    const recipients = emails.map((email) => [5, email, [email], 2]);
    await singleShotApiRequest(SHARE_ALBUM_RPCID, [
      null,
      null,
      options,
      [1, [[albumMediaKey], [1, 2, 3]], null, null, null, null, [1]],
      null,
      [null, recipients],
      null,
      null,
      [1, 2, 3, 5, 6],
    ], `/album/${albumMediaKey}`);
  },
};

export type CuePhotosBridge = typeof bridge;

// callJSON never throws: results cross as one JSON string carrying an {ok, value} or
// {ok:false, error, stack, diag} envelope, so the native side always decodes a real
// message instead of an opaque WKError.
async function callJSON(method: keyof CuePhotosBridge, argsJSON: string): Promise<string> {
  try {
    const args = JSON.parse(argsJSON) as unknown[];
    const fn = bridge[method] as ((...a: unknown[]) => unknown) | undefined;
    if (typeof fn !== 'function') throw new Error(`Unknown bridge method: ${String(method)}`);
    const result = await fn.apply(bridge, args);
    return JSON.stringify({ ok: true, value: result ?? null });
  } catch (e) {
    const err = e instanceof Error ? e : new Error(String(e));
    return JSON.stringify({ ok: false, error: err.message, stack: err.stack ?? null, diag: diag() });
  }
}

declare global {
  interface Window {
    cuePhotos: CuePhotosBridge & { callJSON: typeof callJSON };
  }
}

window.cuePhotos = Object.assign({}, bridge, { callJSON });
