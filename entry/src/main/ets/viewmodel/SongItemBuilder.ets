/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { http } from '@kit.NetworkKit';
import { SongItem } from './SongData';
import Logger from '../common/utils/Logger';
import { NetworkDiagnostics } from '../common/utils/NetworkDiagnostics';
import { wbiSigner } from '../common/utils/BiliWbiUtil';
import { MediaResourceManager } from '../common/utils/MediaResourceManager';
import { getCurrentVersion, isVersionMatch } from '../common/utils/VersionUtil';

const TAG = 'SongItemBuilder';
const AUDIO_QUALITY_ID = 30216;
const MAX_PLAY_URL_ATTEMPTS = 3;

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

class RetryablePlayUrlError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RetryablePlayUrlError';
  }
}

function isRetryableHttpStatus(statusCode: number): boolean {
  return statusCode === 408 || statusCode === 425 || statusCode === 429 ||
    (statusCode >= 500 && statusCode <= 599);
}

function waitBeforeRetry(delayMs: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, delayMs));
}

/**
 * Resolves remote Bilibili media URLs and applies the resolved source to a song.
 * Network retries are deliberately bounded; malformed/business-error responses
 * fail fast, while transient transport and HTTP failures are retried.
 */
export default class SongItemBuilder {
  public async getBiliPlayUrl(
    bvid: string,
    cid: number,
    candidateIndex: number = 0,
    expectedVersion: number = getCurrentVersion()
  ): Promise<string> {
    if (typeof bvid !== 'string' || bvid.trim().length === 0 ||
      !Number.isInteger(cid) || cid <= 0) {
      throw new Error('Invalid Bilibili media identifier');
    }

    const params = new Map<string, string | number>();
    params.set('bvid', bvid.trim());
    params.set('cid', cid);
    params.set('fnval', 16);
    params.set('qn', 16);

    let refreshedWbiKey = false;
    let lastError: Error | undefined = undefined;

    for (let attempt = 1; attempt <= MAX_PLAY_URL_ATTEMPTS; attempt++) {
      if (!isVersionMatch(expectedVersion)) {
        throw new Error('Play URL request was cancelled because the selected song changed');
      }

      const signedParams = await wbiSigner.getSignedParams(params);
      if (!isVersionMatch(expectedVersion)) {
        throw new Error('Play URL request was cancelled because the selected song changed');
      }

      const queryParts: string[] = [];
      signedParams.forEach((value, key) => {
        queryParts.push(`${key}=${encodeURIComponent(value.toString())}`);
      });
      const requestUrl = `https://api.bilibili.com/x/player/wbi/playurl?${queryParts.join('&')}`;
      const httpRequest = http.createHttp();
      const requestStartedAt = Date.now();
      let responseCode: number | undefined = undefined;
      let diagnosticLogged = false;
      let retryDelayMs = 0;

      try {
        let response: http.HttpResponse;
        try {
          response = await httpRequest.request(requestUrl, {
            method: http.RequestMethod.GET,
            header: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
              'Referer': 'https://www.bilibili.com/',
              'Accept-Language': 'zh-CN,zh;q=0.9'
            },
            connectTimeout: 10000,
            readTimeout: 10000
          });
        } catch (error) {
          NetworkDiagnostics.failure(
            TAG,
            'player.playurl',
            requestStartedAt,
            'transport_error',
            attempt,
            undefined,
            undefined,
            NetworkDiagnostics.getSystemErrorCode(error)
          );
          diagnosticLogged = true;
          const message = error instanceof Error ? error.message : String(error);
          throw new RetryablePlayUrlError(message);
        }

        responseCode = response.responseCode;
        if (response.responseCode !== 200) {
          NetworkDiagnostics.failure(TAG, 'player.playurl', requestStartedAt, 'http_error', attempt, response.responseCode);
          diagnosticLogged = true;
          const message = `Play URL request failed: HTTP ${response.responseCode}`;
          if (isRetryableHttpStatus(response.responseCode)) {
            throw new RetryablePlayUrlError(message);
          }
          throw new Error(message);
        }

        if (!isVersionMatch(expectedVersion)) {
          throw new Error('Play URL request was cancelled because the selected song changed');
        }

        let result: BiliPlayUrlResponse;
        try {
          if (typeof response.result !== 'string') {
            throw new Error('Play URL response body is not a JSON string');
          }
          result = JSON.parse(response.result) as BiliPlayUrlResponse;
          if (!result || typeof result !== 'object' || typeof result.code !== 'number') {
            throw new Error('Play URL response has an invalid structure');
          }
        } catch (error) {
          NetworkDiagnostics.failure(TAG, 'player.playurl', requestStartedAt, 'parse_error', attempt, response.responseCode);
          diagnosticLogged = true;
          const message = error instanceof Error ? error.message : String(error);
          throw new Error(message);
        }

        if (result.code !== 0) {
          NetworkDiagnostics.failure(TAG, 'player.playurl', requestStartedAt, 'business_error', attempt, response.responseCode, result.code);
          diagnosticLogged = true;
          // A stale WBI key is a common cause of -403. Refresh once, then sign
          // the request again; never loop indefinitely on risk-control errors.
          if (result.code === -403 && !refreshedWbiKey) {
            refreshedWbiKey = true;
            await wbiSigner.fetchAndCacheWbiKeys(true);
            // Do not spend a transient retry slot on credential refresh.
            // A stale key can be discovered on the last normal attempt too.
            attempt--;
            continue;
          }
          throw new Error(`Bilibili API error: ${result.message || result.code}`);
        }

        const audioStreams = Array.isArray(result.data?.dash?.audio)
          ? result.data?.dash?.audio as BiliAudioStream[]
          : [];
        const selectedAudio = audioStreams.find((item: BiliAudioStream) =>
          item && item.id === AUDIO_QUALITY_ID
        ) ?? audioStreams.find((item: BiliAudioStream) => item && typeof item === 'object');
        if (!selectedAudio) {
          throw new Error('No playable audio stream was returned by Bilibili');
        }

        // Keep the CDN order supplied by Bilibili: baseUrl first, then backupUrl.
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

        if (!isVersionMatch(expectedVersion)) {
          throw new Error('Play URL request was cancelled because the selected song changed');
        }

        const safeCandidateIndex = Number.isInteger(candidateIndex) && candidateIndex >= 0
          ? candidateIndex
          : 0;
        const selectedIndex = Math.min(safeCandidateIndex, candidateUrls.length - 1);
        NetworkDiagnostics.success(TAG, 'player.playurl', requestStartedAt, response.responseCode, attempt);
        diagnosticLogged = true;
        return candidateUrls[selectedIndex];
      } catch (error) {
        const requestWasCancelled = !isVersionMatch(expectedVersion);
        if (!diagnosticLogged && !requestWasCancelled) {
          NetworkDiagnostics.failure(TAG, 'player.playurl', requestStartedAt, 'response_validation_error', attempt, responseCode);
        }
        lastError = error instanceof Error ? error : new Error(String(error));
        const canRetry = error instanceof RetryablePlayUrlError && attempt < MAX_PLAY_URL_ATTEMPTS;
        if (!canRetry) {
          throw new Error(lastError.message);
        }
        retryDelayMs = 350 * Math.pow(2, attempt - 1);
        Logger.warn(TAG, `Play URL request failed temporarily; retrying ${attempt}/${MAX_PLAY_URL_ATTEMPTS} after ${retryDelayMs}ms`);
      } finally {
        try {
          httpRequest.destroy();
        } catch (destroyError) {
          const message = destroyError instanceof Error ? destroyError.message : String(destroyError);
          // Teardown is best-effort: preserve the actual HTTP/API/parse result.
          Logger.warn(TAG, `HTTP client cleanup failed: ${message}`);
        }
      }

      await waitBeforeRetry(retryDelayMs);
    }

    throw lastError || new Error('Play URL request failed after bounded retries');
  }

  public async build(songItem: SongItem, expectedVersion: number = getCurrentVersion()): Promise<void> {
    if (!songItem || !songItem.bvid || !Number.isInteger(songItem.cid) || songItem.cid <= 0) {
      throw new Error('Cannot build song source: invalid Bilibili media identifier');
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

    const remoteUrl = await this.getBiliPlayUrl(songItem.bvid, songItem.cid, 0, expectedVersion);
    if (!isVersionMatch(expectedVersion)) {
      return;
    }
    if (!remoteUrl) {
      throw new Error('Bilibili returned an empty media URL');
    }

    songItem.src = remoteUrl;
    mediaManager.downloadSong(songItem.bvid, remoteUrl);
    Logger.info(TAG, `Resolved remote media URL for ${songItem.bvid}`);
  }
}
