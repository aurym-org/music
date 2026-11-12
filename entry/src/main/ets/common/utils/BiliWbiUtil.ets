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
  private static readonly KEY_TTL_MS: number = 23 * 60 * 60 * 1000;

  async fetchAndCacheWbiKeys(): Promise<void> {
    if (this.fetchPromise) {
      return this.fetchPromise;
    }
    this.fetchPromise = this.doFetchAndCache();
    try {
      await this.fetchPromise;
    } finally {
      this.fetchPromise = null;
    }
  }

  private async doFetchAndCache(): Promise<void> {
    try {
      const cached = await this.getCachedKeys();
      const now = Date.now();
      if (cached && cached.time <= now && now - cached.time < WbiSigner.KEY_TTL_MS) {
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
      }

      const httpRequest = http.createHttp();
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

        if (response.responseCode !== 200) {
          throw new Error(`WBI key request failed: HTTP ${response.responseCode}`);
        }
        const data: BiliWbiResponse = JSON.parse(response.result as string);
        const imgUrl: string = data.data.wbi_img.img_url;
        const subUrl: string = data.data.wbi_img.sub_url;
        if (!imgUrl || !subUrl) {
          throw new Error('WBI key fields are missing from nav response');
        }

        const imgKey = this.extractKeyFromUrl(imgUrl);
        const subKey = this.extractKeyFromUrl(subUrl);
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
        Logger.info(TAG, 'WBI keys fetched and cached');
      } finally {
        httpRequest.destroy();
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `Error fetching WBI keys: ${message}`);
    }
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
        queryParts.push(`${key}=${encodeURIComponent(value.toString())}`);
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
      if (imgKey && subKey && timeStr) {
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
