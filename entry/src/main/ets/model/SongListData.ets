/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { SongItem } from "../viewmodel/SongData";
import { http } from '@kit.NetworkKit';
import Logger from "../common/utils/Logger";
import { FavDetail, FavDetailItemModel } from "../viewmodel/FavDetailItem";
import { ContentConstants } from "../common/constants/ContentConstants";

const TAG = 'SongListData';

function convertToSongItem(item: FavDetailItemModel, index: number): SongItem {
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
 * 获取收藏夹的所有音频（自动分页）
 * @param mediaId 收藏夹 ID
 * @param pageSize 每页数量，固定为 40
 * @returns 包含所有音频项的数组
 */
  async function getFavoriteDetail(mediaId: number, pageSize: number = 40): Promise<void> {
  let currentPage: number = 1;           // 当前页码，从第一页开始
  let hasMore: boolean = true;           // 是否还有更多数据

  songList.length = 0;
  Logger.info(TAG, `开始获取收藏夹 ${mediaId} 的所有歌曲，每页 ${pageSize} 条`);

  while (hasMore) {
    try {
      const url = `https://api.bilibili.com/x/v3/fav/resource/list?media_id=${mediaId}&pn=${currentPage}&ps=${pageSize}&keyword=&order=mtime&type=0&tid=0&platform=web&web_location=0.0`;
      const httpRequest = http.createHttp();
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
      httpRequest.destroy();
      if (response.responseCode !== 200) {
        throw new Error(`HTTP 错误: ${response.responseCode}`);
      }
      const responseData: FavDetail = JSON.parse(response.result as string);
      if (responseData.code !== 0) {
        throw new Error(`API 错误: ${responseData.code} - ${responseData.message}`);
      }

      const currentSongs = responseData.data.medias.map((value, idx) => convertToSongItem(value, idx)) || [];
      Logger.info(TAG, `第 ${currentPage} 页: 获取到 ${currentSongs.length} 条数据`);

      songList = songList.concat(currentSongs);
      AppStorage.setOrCreate('songList', songList);

      hasMore = responseData.data.has_more === true;

      if (hasMore) {
        currentPage++;
      } else {
        Logger.info(TAG, '所有数据获取完毕');
      }

    } catch (error) {
      Logger.error(TAG, `获取第 ${currentPage} 页失败:`, error);
      throw new Error(`获取收藏夹数据失败: ${error.message}`);
    }
  }

  Logger.info(TAG, `总共获取到 ${songList.length} 首歌曲`);
}

let songList: SongItem[] = [];

export { songList, getFavoriteDetail };