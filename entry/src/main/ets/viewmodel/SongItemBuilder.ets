/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { common } from '@kit.AbilityKit';
import { SongItem } from './SongData';
import Logger from '../common/utils/Logger';
import { http } from '@kit.NetworkKit';
import { wbiSigner } from '../common/utils/BiliWbiUtil';
import { SongDownloadManager } from '../common/utils/SongDownloadManager';
import { getCurrentVersion, isVersionMatch } from '../common/utils/VersionUtil';
import { APP_STORAGE_KEYS } from '../common/constants/AppStorageKeys';

const TAG = 'SongItemBuilder'

interface BiliPlayUrl {
  code: number,
  message: string,
  data: data
}

interface data {
  dash: dash
}

interface dash {
  audio: audio[]
}

interface audio {
  id: number,
  backupUrl: string[]
}

export default class SongItemBuilder {
  private context: common.UIAbilityContext | undefined = AppStorage.get(APP_STORAGE_KEYS.CONTEXT);
  private songItem: SongItem | null = null;

  async getBiliPlayUrl(bvid: string, cid: number): Promise<string> {
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
    try {
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
      if (response.responseCode !== 200) {
        throw new Error(`HTTP error: ${response.responseCode}`);
      }
      const result: BiliPlayUrl = JSON.parse(response.result as string);
      if (result.code !== 0) {
        throw new Error(`API error: ${result.message}`);
      }
      const audio = result.data.dash.audio.find(item => item.id === 30216)!;
      const rawUrl = audio.backupUrl.find(u => u.includes('upos-'))!;
      const audioUrl = rawUrl.replace(/^https?:\/\/[^\/]+/, 'https://upos-sz-mirrorali.bilivideo.com');
      return audioUrl;
    } finally {
      httpRequest.destroy();
    }
  }

  public async build(songItem: SongItem): Promise<void> {
    const currentVersion = getCurrentVersion();
    this.songItem = songItem;
    if (!this.context) {
      return;
    }
    const bvid = songItem.bvid;
    if (!bvid) {
      Logger.error(TAG, 'MediaAssetBuilder build: bvid is empty');
      return;
    }

    const songStore = SongDownloadManager.getInstance();
    if (songStore.hasLocalSong(bvid)) {
      if (!isVersionMatch(currentVersion)) return;
      this.songItem.src = songStore.getLocalPath(bvid);
      Logger.info(TAG, 'MediaAssetBuilder build local song:' + this.songItem.src);
      return;
    }
    if (!isVersionMatch(currentVersion)) return;
    try {
      if (!isVersionMatch(currentVersion)) return;
      const targetAudioUrl = await this.getBiliPlayUrl(bvid, this.songItem.cid);
      if (!isVersionMatch(currentVersion)) return;
      this.songItem.src = targetAudioUrl;
      SongDownloadManager.getInstance().startDownload(bvid, targetAudioUrl);
      Logger.info(TAG, 'MediaAssetBuilder build realUrl:' + this.songItem.src);
    } catch (error) {
      Logger.error(TAG, `MediaAssetBuilder build error: ${error.message}`);
      AppStorage.setOrCreate(APP_STORAGE_KEYS.ERROR_MESSAGE, `加载歌曲失败: ${error.message}`);
    }
    return;
  }

  public async release(): Promise<void> {
    this.songItem = null;
  }
}