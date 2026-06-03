/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { common } from '@kit.AbilityKit';
import { SongItem } from './SongData';
import { url } from '@kit.ArkTS';
import Logger from '../common/utils/Logger';
import { http } from '@kit.NetworkKit';
import { PreferencesUtil } from '../common/utils/PreferencesUtil';
import { BiliPlayUrl } from './BiliPlayUrl';
import { wbiSigner } from '../common/utils/BiliWbiUtil';

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
      expire: Number(url.URL.parseURL(raw_url).params.get('deadline')) * 1000
    });
    PreferencesUtil.getInstance().preferencesPut(bvid, data);
  }

  async getAudioUrl(bvid: string): Promise<string | null> {
    const str: string = PreferencesUtil.getInstance().getValue(bvid) as string;

    try {
      const cacheData: CacheData = JSON.parse(str);
      if (cacheData.expire > Date.now()) return cacheData.url;
      await PreferencesUtil.getInstance().removeKey(bvid);
    } catch {
      await PreferencesUtil.getInstance().removeKey(bvid);
    }
    return null;
  }

  cleanHttpRequest() {
    this.currentRequest?.destroy();
    this.currentRequest = null;
  }

  async getBiliPlayUrl(bvid: string, cid: number): Promise<string> {
    await PreferencesUtil.getInstance().removeKey(bvid);
    this.cleanHttpRequest();
    const params = new Map<string, string | number>();
    params.set('bvid', bvid);
    params.set('cid', cid);
    params.set('fnval', 16);
    params.set('qn', 16);
    const signed = await wbiSigner.getSignedParams(params);
    const queryParts: string[] = [];
    signed.forEach((value, key) => {
      queryParts.push(`${key}=${encodeURIComponent(value.toString())}`);
    });
    const url = `https://api.bilibili.com/x/player/wbi/playurl?${queryParts.join('&')}`;
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
    const audioUrl: string = result.data.dash.audio[0].baseUrl;
    this.putAudioUrl(bvid, audioUrl);
    return audioUrl;
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
      const targetAudioUrl = await this.getBiliPlayUrl(bvid, this.songItem.cid);
      if (AppStorage.get<number>('switchVersion') !== currentVersion) return;
      this.songItem.src = targetAudioUrl;
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