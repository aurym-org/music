/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { SongItem } from "../viewmodel/SongData";
import { http } from '@kit.NetworkKit';
import Logger from "../common/utils/Logger";
import { ContentConstants } from "../common/constants/ContentConstants";
import { wbiSigner } from "../common/utils/BiliWbiUtil";
import { BiliMusicParser } from "../common/utils/BiliMusicParser";
import { APP_STORAGE_KEYS } from "../common/constants/AppStorageKeys";

interface BiliFavDetail {
  code: number,
  message: string,
  data: data
}

interface data {
  info: info,
  medias: BiliFavDetailItemModel[],
  has_more: boolean
}

interface info {
  media_count: number
}

interface BiliFavDetailItemModel {
  id: number,
  title: string,
  intro: string,
  upper: upper,
  cover: string,
  bvid: string,
  ugc: ugc
}

interface ugc {
  first_cid: number
}

interface upper {
  name: string
}

interface PageResult {
  page: number,
  songs: SongItem[]
}

interface FavListRequest {
  url: string;
  headers: Record<string, string>;
}

interface PageResultWithTotal {
  songs: SongItem[];
  totalCount: number;
}

const TAG = 'SongListData';
const parser = new BiliMusicParser();

function convertToSongItem(item: BiliFavDetailItemModel, index: number): SongItem {
  const info = parser.parse(item.title, item.intro);
  return {
    id: item.id,
    title: info.title ? info.title : item.title,
    singer: info.singer ? info.singer : item.upper.name,
    label: item.cover + '@672w_378h_1c.webp',
    src: '',
    index: index,
    bvid: item.bvid,
    cid: item.ugc.first_cid
  };
}

/**
 * 构建收藏夹列表请求的 URL 和 Headers
 */
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

/**
 * 请求单页收藏夹数据（带重试）
 */
async function requestPage(
  mediaId: number,
  page: number,
  pageSize: number,
  retries: number = 2
): Promise<PageResultWithTotal> {
  const requestInfo = await buildFavListRequest(mediaId, page, pageSize);
  const url = requestInfo.url;
  const headers = requestInfo.headers;  let lastError: Error | null = null;

  for (let attempt = 0; attempt <= retries; attempt++) {
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
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
      const songs = responseData.data.medias.map((value, idx) => convertToSongItem(value, idx)) || [];
      const totalCount = responseData.data.info?.media_count ?? songs.length;
      return { songs, totalCount };
    } catch (error) {
      lastError = error;
      Logger.warn(TAG, `第 ${page} 页请求失败 (尝试 ${attempt + 1}/${retries + 1}): ${error.message}`);
      if (attempt === retries) {
        throw new Error(`第 ${page} 页加载失败: ${error.message}`);
      }
      await new Promise<void>(resolve => setTimeout(resolve, 500 * Math.pow(2, attempt)));
    } finally {
      httpRequest.destroy();
    }
  }
  throw lastError || new Error(`第 ${page} 页加载失败（未知原因）`);
}

/**
 * 获取收藏夹的所有音频（自动分页，弱网优化）
 * 先请求第一页获取总数，剩余页分批次并发（每批3个），保证列表顺序
 */
async function getFavoriteDetail(mediaId: number, pageSize: number = 40): Promise<void> {
  Logger.info(TAG, `开始获取收藏夹 ${mediaId} 的所有歌曲，每页 ${pageSize} 条`);

  try {
    // 1. 请求第一页，获取总数
    const firstResult = await requestPage(mediaId, 1, pageSize);
    const firstSongs = firstResult.songs;
    const totalCount = firstResult.totalCount;
    const totalPages = Math.ceil(totalCount / pageSize);
    Logger.info(TAG, `共 ${totalCount} 条 (${totalPages} 页)`);

    const allSongs: SongItem[] = new Array(totalCount);
    // 填充第一页
    for (let i = 0; i < firstSongs.length; i++) {
      allSongs[i] = firstSongs[i];
    }

    if (totalPages > 1) {
      const batchSize = 3;
      for (let start = 2; start <= totalPages; start += batchSize) {
        const batch: Promise<PageResult>[] = [];
        for (let p = start; p < start + batchSize && p <= totalPages; p++) {
          batch.push(
            requestPage(mediaId, p, pageSize)
              .then(result => ({ page: p, songs: result.songs } as PageResult))
          );
        }
        const results = await Promise.all(batch);
        for (const result of results) {
          const page = result.page;
          const songs = result.songs;
          const baseIdx = (page - 1) * pageSize;
          for (let i = 0; i < songs.length; i++) {
            allSongs[baseIdx + i] = songs[i];
          }
        }
      }
    }

    AppStorage.setOrCreate(APP_STORAGE_KEYS.SONG_LIST, allSongs);
    Logger.info(TAG, `并发获取完毕`);
  } catch (error) {
    Logger.error(TAG, `获取收藏夹失败:`, error);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.ERROR_MESSAGE, `获取收藏夹数据失败: ${error.message}`);
    throw new Error(`获取收藏夹数据失败: ${error.message}`);
  }
}

export { getFavoriteDetail };