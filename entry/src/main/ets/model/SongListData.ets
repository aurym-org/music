/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { SongItem } from "../viewmodel/SongData";
import { http } from '@kit.NetworkKit';
import Logger from "../common/utils/Logger";
import { BiliFavDetail, BiliFavDetailItemModel } from "../viewmodel/BiliFavDetail";
import { ContentConstants } from "../common/constants/ContentConstants";
import { wbiSigner } from "../common/utils/BiliWbiUtil";

interface PageResult {
  page: number,
  songs: SongItem[]
}

const TAG = 'SongListData';

function convertToSongItem(item: BiliFavDetailItemModel, index: number): SongItem {
  return {
    id: item.id,
    title: item.title,
    singer: item.upper.name,
    label: item.cover + '@.webp',
    src: '',
    index: index,
    bvid: item.bvid,
    cid: item.ugc.first_cid
  };
}

/**
 * 请求单页收藏夹数据
 */
async function requestPage(mediaId: number, page: number, pageSize: number): Promise<SongItem[]> {
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
  const httpRequest = http.createHttp();
  try {
    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'accept': '*/*',
        'accept-language': 'zh-CN,zh;q=0.9',
        'origin': 'https://space.bilibili.com',
        'referer': `https://space.bilibili.com/${ContentConstants.UP_MID}/favlist?fid=${mediaId}&ftype=create`,
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36'
      },
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
    return responseData.data.medias.map((value, idx) => convertToSongItem(value, idx)) || [];
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 获取收藏夹的所有音频（自动分页，弱网优化）
 * 先请求第一页获取总数，剩余页分批次并发（每批3个），保证列表顺序
 */
async function getFavoriteDetail(mediaId: number, pageSize: number = 40): Promise<void> {
  Logger.info(TAG, `开始获取收藏夹 ${mediaId} 的所有歌曲，每页 ${pageSize} 条`);

  try {
    const firstParams = new Map<string, string | number>();
    firstParams.set('media_id', mediaId);
    firstParams.set('pn', 1);
    firstParams.set('ps', pageSize);
    firstParams.set('keyword', '');
    firstParams.set('order', 'mtime');
    firstParams.set('type', 0);
    firstParams.set('tid', 0);
    firstParams.set('platform', 'web');
    firstParams.set('web_location', '0.0');
    const signedFirst = await wbiSigner.getSignedParams(firstParams);
    const firstQueryParts: string[] = [];
    signedFirst.forEach((value, key) => {
      firstQueryParts.push(`${key}=${encodeURIComponent(value.toString())}`);
    });
    const firstUrl = `https://api.bilibili.com/x/v3/fav/resource/list?${firstQueryParts.join('&')}`;

    const firstHttp = http.createHttp();
    let firstResponse: http.HttpResponse;
    try {
      firstResponse = await firstHttp.request(firstUrl, {
        method: http.RequestMethod.GET,
        header: {
          'accept': '*/*',
          'accept-language': 'zh-CN,zh;q=0.9',
          'origin': 'https://space.bilibili.com',
          'referer': `https://space.bilibili.com/${ContentConstants.UP_MID}/favlist?fid=${mediaId}&ftype=create`,
          'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36'
        },
        connectTimeout: 10000,
        readTimeout: 10000
      });
    } finally {
      firstHttp.destroy();
    }

    if (firstResponse.responseCode !== 200) {
      throw new Error(`第一页 HTTP 错误: ${firstResponse.responseCode}`);
    }
    const firstData: BiliFavDetail = JSON.parse(firstResponse.result as string);
    if (firstData.code !== 0) {
      throw new Error(`第一页 API 错误: ${firstData.code} - ${firstData.message}`);
    }

    const firstSongs = firstData.data.medias.map((value, idx) => convertToSongItem(value, idx)) || [];

    let totalCount: number = firstData.data.info.media_count;
    const totalPages = Math.ceil(totalCount / pageSize);
    Logger.info(TAG, `共 ${totalCount} 条 (${totalPages} 页)`);
    const allSongs: SongItem[] = new Array(totalCount);
    for (let i = 0; i < firstSongs.length; i++) {
      allSongs[i] = firstSongs[i];
    }

    if (totalPages > 1) {
      const batchSize = 3;
      for (let start = 2; start <= totalPages; start += batchSize) {
        const batch: Promise<PageResult>[] = [];
        for (let p = start; p < start + batchSize && p <= totalPages; p++) {
          batch.push(
            requestPage(mediaId, p, pageSize).then(songs => ({ page: p, songs } as PageResult))
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

    AppStorage.setOrCreate('songList', allSongs);
    Logger.info(TAG, `并发获取完毕`);
  } catch (error) {
    Logger.error(TAG, `获取收藏夹失败:`, error);
    AppStorage.setOrCreate('errorMessage', `获取收藏夹数据失败: ${error.message}`);
    throw new Error(`获取收藏夹数据失败: ${error.message}`);
  }
}

export { getFavoriteDetail };