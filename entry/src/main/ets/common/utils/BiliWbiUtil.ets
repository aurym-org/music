/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { PreferencesUtil } from './PreferencesUtil';
import Logger from './Logger';
import { NetworkDiagnostics } from './NetworkDiagnostics';

interface BiliWbiInfo {
  imgKey: string,
  subKey: string,
  time: number
}

interface BiliWbiResponse {
  data: BiliWbiData
}

interface BiliWbiData {
  wbi_img: BiliWbiImage
}

interface BiliWbiImage {
  img_url: string,
  sub_url: string
}

const TAG = 'BiliWbiUtil';
const MIXIN_KEY_ENC_TAB = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
  27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
  37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
  22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
];

class WbiSigner {
  private imgKey: string = '';
  private subKey: string = '';
  private mixinKey: string = '';
  private fetchPromise: Promise<void> | null = null;
  private keyExpiresAt: number = 0;
  private forcedRefreshGeneration: number = 0;
  private static readonly KEY_TTL_MS: number = 23 * 60 * 60 * 1000;
  private static readonly MAX_KEY_FETCH_ATTEMPTS: number = 3;

  private hasUsableKey(): boolean {
    return this.mixinKey.length === 32 && Date.now() < this.keyExpiresAt;
  }

  async fetchAndCacheWbiKeys(forceRefresh: boolean = false): Promise<void> {
    const refreshGenerationAtCall = this.forcedRefreshGeneration;
    if (!forceRefresh && this.hasUsableKey()) {
      return;
    }

    while (this.fetchPromise) {
      const pendingFetch = this.fetchPromise;
      try {
        await pendingFetch;
      } catch (error) {
        // A force-refresh caller must still be able to replace a failed normal
        // fetch. Normal callers receive the original failure without spawning
        // a storm of duplicate requests.
        if (!forceRefresh) {
          const message = error instanceof Error ? error.message : String(error);
          throw new Error(message);
        }
      }
      if (!forceRefresh && this.hasUsableKey()) {
        return;
      }
      if (forceRefresh && this.forcedRefreshGeneration > refreshGenerationAtCall) {
        return;
      }
    }

    if (!forceRefresh && this.hasUsableKey()) {
      return;
    }

    this.fetchPromise = this.doFetchAndCache(forceRefresh);
    const pendingFetch = this.fetchPromise;
    try {
      await pendingFetch;
      if (!this.hasUsableKey()) {
        throw new Error('WBI key fetch completed without a usable signing key');
      }
      if (forceRefresh) {
        this.forcedRefreshGeneration++;
      }
    } finally {
      if (this.fetchPromise === pendingFetch) {
        this.fetchPromise = null;
      }
    }
  }

  private async doFetchAndCache(forceRefresh: boolean = false): Promise<void> {
    if (forceRefresh) {
      // Do not silently fall back to a key that the server has just rejected.
      this.imgKey = '';
      this.subKey = '';
      this.mixinKey = '';
      this.keyExpiresAt = 0;
      PreferencesUtil.getInstance().preferencesPut(WbiSigner.CACHE_KEY_TIME, '0');
    } else {
      const cached = await this.getCachedKeys();
      const now = Date.now();
      if (cached && cached.time <= now && now - cached.time < WbiSigner.KEY_TTL_MS &&
        /^[A-Za-z0-9_-]{32}$/.test(cached.imgKey) && /^[A-Za-z0-9_-]{32}$/.test(cached.subKey)) {
        const cachedMixinKey = this.generateMixinKey(cached.imgKey, cached.subKey);
        if (cachedMixinKey.length === 32) {
          this.imgKey = cached.imgKey;
          this.subKey = cached.subKey;
          this.mixinKey = cachedMixinKey;
          this.keyExpiresAt = cached.time + WbiSigner.KEY_TTL_MS;
          Logger.info(TAG, 'WBI keys loaded from cache');
          return;
        }
        Logger.warn(TAG, 'Cached WBI keys are invalid; fetching fresh keys');
      } else if (cached) {
        Logger.warn(TAG, 'Cached WBI key components are malformed; fetching fresh keys');
      }
    }

    let lastError: Error = new Error('WBI key request failed');
    for (let attempt = 1; attempt <= WbiSigner.MAX_KEY_FETCH_ATTEMPTS; attempt++) {
      const httpRequest = http.createHttp();
      const requestStartedAt = Date.now();
      let responseCode: number | undefined = undefined;
      let canRetry = false;
      try {
        const response = await httpRequest.request('https://api.bilibili.com/x/web-interface/nav', {
          method: http.RequestMethod.GET,
          header: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': 'https://www.bilibili.com/'
          },
          connectTimeout: 10000,
          readTimeout: 10000
        });

        responseCode = response.responseCode;
        if (response.responseCode !== 200) {
          canRetry = response.responseCode === 408 || response.responseCode === 425 ||
            response.responseCode === 429 || response.responseCode >= 500;
          throw new Error(`WBI key request failed: HTTP ${response.responseCode}`);
        }
        if (typeof response.result !== 'string') {
          throw new Error('WBI key response body is not a JSON string');
        }

        const responseData: BiliWbiResponse = JSON.parse(response.result);
        const imgUrl = responseData.data?.wbi_img?.img_url;
        const subUrl = responseData.data?.wbi_img?.sub_url;
        if (typeof imgUrl !== 'string' || typeof subUrl !== 'string' ||
          !/^https?:\/\//i.test(imgUrl) || !/^https?:\/\//i.test(subUrl)) {
          throw new Error('WBI key fields are missing or invalid in nav response');
        }

        const imgKey = this.extractKeyFromUrl(imgUrl);
        const subKey = this.extractKeyFromUrl(subUrl);
        if (imgKey.length !== 32 || subKey.length !== 32) {
          throw new Error('WBI image key fields must each contain exactly 32 characters');
        }
        const mixinKey = this.generateMixinKey(imgKey, subKey);
        if (mixinKey.length !== 32) {
          throw new Error('Failed to generate a valid WBI mixin key');
        }

        const fetchedAt = Date.now();
        this.imgKey = imgKey;
        this.subKey = subKey;
        this.mixinKey = mixinKey;
        this.keyExpiresAt = fetchedAt + WbiSigner.KEY_TTL_MS;
        await this.cacheKeys(this.imgKey, this.subKey, fetchedAt);
        NetworkDiagnostics.success(TAG, 'wbi.nav', requestStartedAt, response.responseCode, attempt);
        Logger.info(TAG, 'WBI keys fetched and cached');
        return;
      } catch (error) {
        lastError = error instanceof Error ? error : new Error(String(error));
        if (responseCode === undefined) {
          // Transport failures are retryable; malformed JSON and invalid key
          // payloads are deterministic and should fail fast.
          canRetry = true;
        }
        NetworkDiagnostics.failure(
          TAG,
          'wbi.nav',
          requestStartedAt,
          responseCode === undefined ? 'transport_error' : 'request_or_parse_error',
          attempt,
          responseCode,
          undefined,
          NetworkDiagnostics.getSystemErrorCode(error)
        );
        Logger.warn(TAG, `WBI key request attempt ${attempt} failed: ${lastError.message}`);
      } finally {
        try {
          httpRequest.destroy();
        } catch {
          // Destroy is best-effort; the primary request outcome is preserved.
        }
      }

      if (!canRetry || attempt === WbiSigner.MAX_KEY_FETCH_ATTEMPTS) {
        break;
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 300 * Math.pow(2, attempt - 1)));
    }

    this.imgKey = '';
    this.subKey = '';
    this.mixinKey = '';
    this.keyExpiresAt = 0;
    throw lastError;
  }

  async getSignedParams(params: Map<string, string | number>): Promise<Map<string, string | number>> {
    if (!this.mixinKey || Date.now() >= this.keyExpiresAt) {
      await this.fetchAndCacheWbiKeys();
    }
    if (!this.mixinKey || Date.now() >= this.keyExpiresAt) {
      throw new Error('WBI mixin key is unavailable or expired');
    }

    const signedParams = new Map(params);
    const wts = Math.floor(Date.now() / 1000);
    signedParams.set('wts', wts);

    const sortedKeys = Array.from(signedParams.keys()).sort();
    const queryParts: string[] = [];
    for (const key of sortedKeys) {
      const value = signedParams.get(key);
      if (value !== undefined) {
        queryParts.push(`${key}=${encodeURIComponent(value.toString()).replace(/[!'()*]/g, '')}`);
      }
    }
    const queryString = queryParts.join('&');

    const wRid = await this.md5(queryString + this.mixinKey);
    signedParams.set('w_rid', wRid);
    return signedParams;
  }

  private extractKeyFromUrl(url: string): string {
    const normalizedUrl = url.split('?')[0].split('#')[0];
    const filename = normalizedUrl.substring(normalizedUrl.lastIndexOf('/') + 1);
    const key = filename.split('.')[0];
    return key;
  }

  private generateMixinKey(imgKey: string, subKey: string): string {
    const combined = imgKey + subKey;
    let mixin = '';
    for (const idx of MIXIN_KEY_ENC_TAB) {
      if (idx < combined.length) {
        mixin += combined[idx];
      }
    }
    return mixin.substring(0, 32);
  }

  private async md5(input: string): Promise<string> {
    const md5Generator = cryptoFramework.createMd('MD5');
    await md5Generator.update({ data: new util.TextEncoder().encodeInto(input) });
    const result = await md5Generator.digest();
    return Array.from(new Uint8Array(result.data))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');
  }

  private static readonly CACHE_KEY_IMG = 'wbi_img_key';
  private static readonly CACHE_KEY_SUB = 'wbi_sub_key';
  private static readonly CACHE_KEY_TIME = 'wbi_cache_time';

  private async cacheKeys(imgKey: string, subKey: string, savedAt: number): Promise<void> {
    const prefs = PreferencesUtil.getInstance();
    prefs.preferencesPut(WbiSigner.CACHE_KEY_IMG, imgKey);
    prefs.preferencesPut(WbiSigner.CACHE_KEY_SUB, subKey);
    prefs.preferencesPut(WbiSigner.CACHE_KEY_TIME, savedAt.toString());
  }

  private async getCachedKeys(): Promise<BiliWbiInfo | null> {
    try {
      const prefs = PreferencesUtil.getInstance();
      const imgKey = prefs.getValue(WbiSigner.CACHE_KEY_IMG) as string;
      const subKey = prefs.getValue(WbiSigner.CACHE_KEY_SUB) as string;
      const timeStr = prefs.getValue(WbiSigner.CACHE_KEY_TIME) as string;
      if (typeof imgKey === 'string' && imgKey.length > 0 &&
        typeof subKey === 'string' && subKey.length > 0 &&
        typeof timeStr === 'string' && timeStr.length > 0) {
        const time = Number(timeStr);
        if (Number.isFinite(time) && time > 0) {
          return { imgKey, subKey, time };
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `Error reading WBI cache: ${message}`);
    }
    return null;
  }
}

export const wbiSigner = new WbiSigner();
