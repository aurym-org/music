/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { http } from '@kit.NetworkKit';
import { SongItem } from './SongData';
import Logger from '../common/utils/Logger';
import { wbiSigner } from '../common/utils/BiliWbiUtil';
import { MediaResourceManager } from '../common/utils/MediaResourceManager';
import { getCurrentVersion, isVersionMatch } from '../common/utils/VersionUtil';
import { APP_STORAGE_KEYS } from '../common/constants/AppStorageKeys';

const TAG = 'SongItemBuilder';
const AUDIO_QUALITY_ID = 30216;

interface BiliPlayUrlResponse {
  code: number;
  message: string;
  data?: BiliPlayUrlData;
}

interface BiliPlayUrlData {
  dash?: BiliDashData;
}

interface BiliDashData {
  audio?: BiliAudioStream[];
}

interface BiliAudioStream {
  id: number;
  baseUrl?: string;
  base_url?: string;
  backupUrl?: string[];
  backup_url?: string[];
}

/**
 * Resolves remote Bilibili media URLs and applies the resolved source to a song.
 */
export default class SongItemBuilder {
  public async getBiliPlayUrl(
    bvid: string,
    cid: number,
    candidateIndex: number = 0
  ): Promise<string> {
    if (!bvid || !Number.isInteger(cid) || cid <= 0) {
      throw new Error('Invalid Bilibili media identifier');
    }

    const params = new Map<string, string | number>();
    params.set('bvid', bvid);
    params.set('cid', cid);
    params.set('fnval', 16);
    params.set('qn', 16);

    const signedParams = await wbiSigner.getSignedParams(params);
    const queryParts: string[] = [];
    signedParams.forEach((value, key) => {
      queryParts.push(`${key}=${encodeURIComponent(value.toString())}`);
    });

    const requestUrl = `https://api.bilibili.com/x/player/wbi/playurl?${queryParts.join('&')}`;
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(requestUrl, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
          'Referer': 'https://www.bilibili.com/',
          'Accept-Language': 'zh-CN,zh;q=0.9'
        },
        connectTimeout: 10000,
        readTimeout: 10000
      });

      if (response.responseCode !== 200) {
        throw new Error(`Play URL request failed: HTTP ${response.responseCode}`);
      }

      const result: BiliPlayUrlResponse = JSON.parse(response.result as string);
      if (result.code !== 0) {
        throw new Error(`Bilibili API error: ${result.message || result.code}`);
      }

      const audioStreams = result.data?.dash?.audio ?? [];
      const selectedAudio = audioStreams.find((item: BiliAudioStream) => item.id === AUDIO_QUALITY_ID)
        ?? audioStreams[0];
      if (!selectedAudio) {
        throw new Error('No playable audio stream was returned by Bilibili');
      }

      // Keep the CDN order supplied by Bilibili: baseUrl first, then backupUrl.
      // A failed request will call this method with an increasing candidateIndex
      // so retries actually move to another CDN instead of selecting the same URL.
      const candidateUrls: string[] = [];
      const appendCandidate = (value: string | undefined): void => {
        if (typeof value !== 'string') {
          return;
        }
        const normalized = value.trim();
        if (!/^https?:\/\/[^\/\s]+(?:\/|$)/i.test(normalized)) {
          return;
        }
        if (!candidateUrls.includes(normalized)) {
          candidateUrls.push(normalized);
        }
      };

      appendCandidate(selectedAudio.baseUrl);
      appendCandidate(selectedAudio.base_url);

      const backupUrls: string[] = [];
      if (Array.isArray(selectedAudio.backupUrl)) {
        for (let index = 0; index < selectedAudio.backupUrl.length; index++) {
          backupUrls.push(selectedAudio.backupUrl[index]);
        }
      }
      if (Array.isArray(selectedAudio.backup_url)) {
        for (let index = 0; index < selectedAudio.backup_url.length; index++) {
          backupUrls.push(selectedAudio.backup_url[index]);
        }
      }
      for (const backupUrl of backupUrls) {
        appendCandidate(backupUrl);
      }

      if (candidateUrls.length === 0) {
        throw new Error('The selected audio stream does not contain a playable HTTP(S) URL');
      }

      const safeCandidateIndex = Number.isInteger(candidateIndex) && candidateIndex >= 0
        ? candidateIndex
        : 0;
      // When Bilibili returns fewer backups than the retry limit, reuse the
      // last valid address after refreshing its signed URL from the API.
      const selectedIndex = Math.min(safeCandidateIndex, candidateUrls.length - 1);
      return candidateUrls[selectedIndex];
    } finally {
      httpRequest.destroy();
    }
  }

  public async build(songItem: SongItem, expectedVersion: number = getCurrentVersion()): Promise<void> {
    if (!songItem.bvid) {
      throw new Error('Cannot build song source: bvid is empty');
    }
    if (!isVersionMatch(expectedVersion)) {
      return;
    }

    const mediaManager = MediaResourceManager.getInstance();
    if (mediaManager.hasSong(songItem.bvid)) {
      songItem.src = mediaManager.getSongPath(songItem.bvid);
      Logger.info(TAG, `Using cached media for ${songItem.bvid}`);
      return;
    }

    const remoteUrl = await this.getBiliPlayUrl(songItem.bvid, songItem.cid);
    if (!isVersionMatch(expectedVersion)) {
      return;
    }

    songItem.src = remoteUrl;
    mediaManager.downloadSong(songItem.bvid, remoteUrl);
    Logger.info(TAG, `Resolved remote media URL for ${songItem.bvid}`);
  }

}
