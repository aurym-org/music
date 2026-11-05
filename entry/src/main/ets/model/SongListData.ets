/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { SongItem } from '../viewmodel/SongData';
import { http } from '@kit.NetworkKit';
import Logger from '../common/utils/Logger';
import { ContentConstants } from '../common/constants/ContentConstants';
import { wbiSigner } from '../common/utils/BiliWbiUtil';
import { BiliMusicParser } from '../common/utils/BiliMusicParser';
import { BiliFavDetail, BiliFavDetailItemModel } from '../viewmodel/BiliFavDetail';

interface FavListRequest {
  url: string;
  headers: Record<string, string>;
}

interface PageResult {
  songs: SongItem[];
  rawCount: number;
  totalCount?: number;
  hasMore: boolean;
}

const MAX_FALLBACK_PAGES = 300;
const API_MAX_PAGE_SIZE = 20;
const BATCH_SIZE = 3;

const TAG = 'SongListData';
const parser = new BiliMusicParser();

/** Convert only valid playable video records; ignore audio/collection/deleted items. */
function convertToSongItem(item: BiliFavDetailItemModel, index: number): SongItem | undefined {
  if (!item || typeof item !== 'object') {
    return undefined;
  }
  if (item.type !== undefined && item.type !== 2) {
    return undefined;
  }
  if (item.attr !== undefined && item.attr !== 0) {
    return undefined;
  }

  const rawBvid = typeof item.bvid === 'string' && item.bvid.trim().length > 0
    ? item.bvid
    : item.bv_id;
  const bvid = typeof rawBvid === 'string' ? rawBvid.trim() : '';
  const cid = item.ugc?.first_cid;
  const title = typeof item.title === 'string' ? item.title.trim() : '';
  if (!bvid || !title || typeof cid !== 'number' || !Number.isInteger(cid) || cid <= 0) {
    return undefined;
  }

  const info = parser.parse(item);
  const cover = typeof item.cover === 'string' ? item.cover.trim() : '';
  const singer = info.singer || item.upper?.name || '';
  return {
    id: item.id,
    title: info.title || title,
    singer,
    label: cover ? `${cover}@384w_216h.avif` : '',
    src: '',
    index,
    bvid,
    cid
  };
}

/** Build the signed request URL and headers for one favorite-list page. */
async function buildFavListRequest(
  mediaId: number,
  page: number,
  pageSize: number
): Promise<FavListRequest> {
  const params = new Map<string, string | number>();
  params.set('media_id', mediaId);
  params.set('pn', page);
  params.set('ps', pageSize);
  params.set('keyword', '');
  params.set('order', 'mtime');
  params.set('type', 0);
  params.set('tid', 0);
  params.set('platform', 'web');
  params.set('web_location', '0.0');

  const signedParams = await wbiSigner.getSignedParams(params);
  const queryParts: string[] = [];
  signedParams.forEach((value, key) => {
    queryParts.push(`${key}=${encodeURIComponent(value.toString())}`);
  });
  const url = `https://api.bilibili.com/x/v3/fav/resource/list?${queryParts.join('&')}`;
  const headers: Record<string, string> = {
    'accept': '*/*',
    'accept-language': 'zh-CN,zh;q=0.9',
    'origin': 'https://space.bilibili.com',
    'referer': `https://space.bilibili.com/${ContentConstants.UP_MID}/favlist?fid=${mediaId}&ftype=create`,
    'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36'
  };
  return { url, headers };
}

/** Request one page with bounded retries and always release the HTTP client. */
async function requestPage(
  mediaId: number,
  page: number,
  pageSize: number,
  retries: number = 2
): Promise<PageResult> {
  const requestInfo = await buildFavListRequest(mediaId, page, pageSize);
  let lastError: Error | null = null;

  for (let attempt = 0; attempt <= retries; attempt++) {
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(requestInfo.url, {
        method: http.RequestMethod.GET,
        header: requestInfo.headers,
        connectTimeout: 10000,
        readTimeout: 10000
      });

      if (response.responseCode !== 200) {
        throw new Error(`HTTP 错误: ${response.responseCode}`);
      }
      const responseData: BiliFavDetail = JSON.parse(response.result as string);
      if (responseData.code !== 0) {
        throw new Error(`API 错误: ${responseData.code} - ${responseData.message}`);
      }
      const pageData = responseData.data;
      if (!pageData || !Array.isArray(pageData.medias)) {
        throw new Error('收藏夹接口返回的数据格式不正确');
      }

      const songs: SongItem[] = [];
      for (let idx = 0; idx < pageData.medias.length; idx++) {
        const song = convertToSongItem(pageData.medias[idx], (page - 1) * pageSize + idx);
        if (song) {
          songs.push(song);
        }
      }

      const rawTotalCount = pageData.info?.media_count;
      const totalCount = typeof rawTotalCount === 'number' &&
        Number.isFinite(rawTotalCount) && rawTotalCount >= 0
        ? rawTotalCount
        : undefined;
      return {
        songs,
        rawCount: pageData.medias.length,
        totalCount,
        hasMore: pageData.has_more === true
      };
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      const errorMessage = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `第 ${page} 页请求失败 (尝试 ${attempt + 1}/${retries + 1}): ${errorMessage}`);
      if (attempt === retries) {
        throw new Error(`第 ${page} 页加载失败: ${errorMessage}`);
      }
      await new Promise<void>(resolve => setTimeout(resolve, 500 * Math.pow(2, attempt)));
    } finally {
      httpRequest.destroy();
    }
  }
  throw lastError || new Error(`第 ${page} 页加载失败（未知原因）`);
}

function appendPageSongs(target: SongItem[], result: PageResult): void {
  for (const song of result.songs) {
    target.push(song);
  }
}

/**
 * Fetch all playable video entries from a Bilibili favorite folder.
 * The API accepts at most 20 records per page; batches preserve page order.
 */
async function getFavoriteDetail(mediaId: number, pageSize: number = API_MAX_PAGE_SIZE): Promise<SongItem[]> {
  Logger.info(TAG, `开始获取收藏夹 ${mediaId} 的所有歌曲，每页 ${pageSize} 条`);

  try {
    if (!Number.isInteger(mediaId) || mediaId <= 0) {
      throw new Error('收藏夹 ID 无效');
    }
    if (!Number.isInteger(pageSize) || pageSize <= 0) {
      throw new Error('分页大小必须是正整数');
    }

    const effectivePageSize = Math.min(pageSize, API_MAX_PAGE_SIZE);
    if (effectivePageSize !== pageSize) {
      Logger.warn(TAG, `接口每页最多返回 ${API_MAX_PAGE_SIZE} 条，已将 pageSize 从 ${pageSize} 调整为 ${effectivePageSize}`);
    }

    const firstResult = await requestPage(mediaId, 1, effectivePageSize);
    const allSongs: SongItem[] = [...firstResult.songs];
    const totalPages = firstResult.totalCount === undefined
      ? undefined
      : Math.ceil(firstResult.totalCount / effectivePageSize);
    // media_count counts raw favorite resources, including entries that this
    // video-only player intentionally skips. Compare against raw API records,
    // not the filtered playable-song count.
    const countSuggestsMore = firstResult.totalCount !== undefined &&
      firstResult.totalCount > firstResult.rawCount;
    const countConflictsWithHasMore = firstResult.totalCount === undefined ||
      countSuggestsMore !== firstResult.hasMore;

    if (totalPages !== undefined) {
      Logger.info(TAG, `共 ${firstResult.totalCount} 条原始收藏资源，预计 ${totalPages} 页`);
    }
    if (countConflictsWithHasMore) {
      Logger.warn(TAG, '收藏夹总数缺失或与 has_more 冲突，将结合总数估算与 has_more 继续分页');
    }

    let nextPage = 2;
    let hasMore = firstResult.hasMore;
    let countEstimateExhausted = firstResult.rawCount === 0 && !firstResult.hasMore &&
      (totalPages === undefined || totalPages <= 1);

    // Continue when either the API continuation flag or the total-count
    // estimate indicates more data. The estimate is advisory: an empty page
    // with has_more=false terminates stale over-reported counts.
    while (hasMore || (!countEstimateExhausted && totalPages !== undefined && nextPage <= totalPages)) {
      if (nextPage > MAX_FALLBACK_PAGES) {
        throw new Error(`收藏夹分页超过安全上限 ${MAX_FALLBACK_PAGES}`);
      }

      const canBatch = !countConflictsWithHasMore && totalPages !== undefined && nextPage <= totalPages;
      const batchEnd = canBatch
        ? Math.min(nextPage + BATCH_SIZE - 1, totalPages as number, MAX_FALLBACK_PAGES)
        : nextPage;
      const batch: Promise<PageResult>[] = [];
      for (let page = nextPage; page <= batchEnd; page++) {
        batch.push(requestPage(mediaId, page, effectivePageSize));
      }
      const results = await Promise.all(batch);

      let lastProcessedPage = nextPage - 1;
      for (const result of results) {
        appendPageSongs(allSongs, result);
        lastProcessedPage++;
        hasMore = result.hasMore;

        // An empty page with no continuation is a reliable stopping signal,
        // even when the folder's media_count is stale and over-reports items.
        if (result.rawCount === 0 && !result.hasMore) {
          countEstimateExhausted = true;
          hasMore = false;
          break;
        }
      }
      nextPage = lastProcessedPage + 1;
    }

    // Reindex after filtering so the UI receives a dense zero-based list.
    for (let index = 0; index < allSongs.length; index++) {
      allSongs[index].index = index;
    }

    Logger.info(TAG, `收藏夹获取完毕，共 ${allSongs.length} 首可播放歌曲`);
    return allSongs;
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    Logger.error(TAG, `获取收藏夹失败: ${errorMessage}`);
    throw new Error(`获取收藏夹数据失败: ${errorMessage}`);
  }
}

export { getFavoriteDetail };
