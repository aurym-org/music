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

import { common } from '@kit.AbilityKit';
import { SongItem } from './SongData';
import { url } from '@kit.ArkTS';
import Logger from '../common/utils/Logger';
import { http } from '@kit.NetworkKit';
import { PreferencesUtil } from '../common/utils/PreferencesUtil';
import { BiliPlayUrl } from './BiliPlayUrl';

const TAG = 'SongItemBuilder'

interface CacheData {
  url: string,
  expire: number
}

export default class SongItemBuilder {
  private context: common.UIAbilityContext | undefined = AppStorage.get('context');
  private songItem: SongItem | null = null;
  private currentRequest: http.HttpRequest | null = null;

  putAudioUrl(bvid: string, raw_url: string): void {
    const data = JSON.stringify({
      url: raw_url,
      expire: Number(url.URL.parseURL(raw_url).params.get('deadline'))
    });
    PreferencesUtil.getInstance().preferencesPut(bvid, data);
  }

  async getAudioUrl(bvid: string): Promise<string | null> {
    const str: string = PreferencesUtil.getInstance().getValue(bvid) as string;

    try {
      const cacheData: CacheData = JSON.parse(str);
      if (cacheData.expire > Date.now()) return cacheData.url;
      await PreferencesUtil.getInstance().removeKey(bvid);   // 过期删除
    } catch {
      await PreferencesUtil.getInstance().removeKey(bvid);    // 数据损坏删除
    }
    return null;
  }

  cleanHttpRequest() {
    this.currentRequest?.destroy();
    this.currentRequest = null;
  }

  async getBiliPlayUrl(bvid: string, cid: number): Promise<BiliPlayUrl> {
    this.cleanHttpRequest();
    const url = `https://api.bilibili.com/x/player/playurl?cid=${cid}&bvid=${bvid}&fnval=16`;
    const httpRequest = http.createHttp();
    this.currentRequest = httpRequest;
    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'https://www.bilibili.com/',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });
    this.cleanHttpRequest();
    if (response.responseCode !== 200) {
      throw new Error(`HTTP error: ${response.responseCode}`);
    }
    const result: BiliPlayUrl = JSON.parse(response.result as string);
    if (result.code !== 0) {
      throw new Error(`API error: ${result.message}`);
    }
    return result;
  }

  public async build(songItem: SongItem): Promise<void> {
    const currentVersion = AppStorage.get<number>('switchVersion') ?? 0;
    this.songItem = songItem;
    if (!this.context) {
      return;
    }
    const bvid = songItem.bvid;
    if (!bvid) {
      Logger.error(TAG, 'MediaAssetBuilder build: bvid is empty');
      return;
    }
    let realUrl = await this.getAudioUrl(bvid);
    if (realUrl) {
      if (AppStorage.get<number>('switchVersion') !== currentVersion) return;
      this.songItem.src = realUrl;
      return;
    }
    if (AppStorage.get<number>('switchVersion') !== currentVersion) return;
    try {
      if (AppStorage.get<number>('switchVersion') !== currentVersion) return;
      const playUrlResult = await this.getBiliPlayUrl(bvid, this.songItem.cid);
      const audioList = playUrlResult.data.dash.audio;
      if (!audioList || !Array.isArray(audioList)) {
        throw new Error('No audio list in playinfo');
      }

      const targetAudio = audioList.find(audio => audio.id === 30216);
      if (!targetAudio || !targetAudio.baseUrl) {
        throw new Error('Audio with id 30216 not found or missing baseUrl');
      }
      if (AppStorage.get<number>('switchVersion') !== currentVersion) return;

      this.putAudioUrl(bvid, targetAudio.baseUrl);
      this.songItem.src = targetAudio.baseUrl;
      Logger.info(TAG, 'MediaAssetBuilder build realUrl:' + this.songItem.src);
    } catch (error) {
      Logger.error(TAG, `MediaAssetBuilder build error: ${error.message}`);
    }
    return;
  }

  public async release(): Promise<void> {
    this.songItem = null;
  }
}