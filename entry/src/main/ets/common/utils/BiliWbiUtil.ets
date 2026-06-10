/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { PreferencesUtil } from './PreferencesUtil';
import { BiliWbiInfo, BiliWbiResponse } from '../../viewmodel/BiliWbi';
import Logger from './Logger';

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
      if (cached && (now - cached.time < 23 * 60 * 60 * 1000)) {
        this.imgKey = cached.imgKey;
        this.subKey = cached.subKey;
        this.mixinKey = this.generateMixinKey(this.imgKey, this.subKey);
        Logger.info(TAG, 'WBI keys loaded from cache');
        return;
      }

      const httpRequest = http.createHttp();
      const response = await httpRequest.request('https://api.bilibili.com/x/web-interface/nav', {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/'
        }
      });

      if (response.responseCode === 200) {
        const data: BiliWbiResponse = JSON.parse(response.result as string);
        const imgUrl: string = data.data.wbi_img.img_url;
        const subUrl: string = data.data.wbi_img.sub_url;
        if (imgUrl && subUrl) {
          this.imgKey = this.extractKeyFromUrl(imgUrl);
          this.subKey = this.extractKeyFromUrl(subUrl);
          this.mixinKey = this.generateMixinKey(this.imgKey, this.subKey);
          await this.cacheKeys(this.imgKey, this.subKey);
          Logger.info(TAG, 'WBI keys fetched and cached');
        } else {
          Logger.error(TAG, 'Failed to parse WBI keys from nav response');
        }
      }
      httpRequest.destroy();
    } catch (e) {
      Logger.error(TAG, 'Error fetching WBI keys', e);
    }
  }

  async getSignedParams(params: Map<string, string | number>): Promise<Map<string, string | number>> {
    if (!this.mixinKey) {
      await this.fetchAndCacheWbiKeys();
      if (!this.mixinKey) throw new Error('WBI mixin key not available');
    }

    const signedParams = new Map(params);
    const wts = Math.floor(Date.now() / 1000);
    signedParams.set('wts', wts);

    const sortedKeys = Array.from(signedParams.keys()).sort();
    const queryString = sortedKeys
      .map(k => `${k}=${encodeURIComponent(signedParams.get(k)!.toString())}`)
      .join('&');

    const wRid = await this.md5(queryString + this.mixinKey);
    signedParams.set('w_rid', wRid);
    return signedParams;
  }

  private extractKeyFromUrl(url: string): string {
    const parts = url.split('/');
    const filename = parts[parts.length - 1];
    return filename.split('.')[0];
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

  private async cacheKeys(imgKey: string, subKey: string): Promise<void> {
    const prefs = PreferencesUtil.getInstance();
    prefs.preferencesPut(WbiSigner.CACHE_KEY_IMG, imgKey);
    prefs.preferencesPut(WbiSigner.CACHE_KEY_SUB, subKey);
    prefs.preferencesPut(WbiSigner.CACHE_KEY_TIME, Date.now().toString());
  }

  private async getCachedKeys(): Promise<BiliWbiInfo | null> {
    try {
      const prefs = PreferencesUtil.getInstance();
      const imgKey = prefs.getValue(WbiSigner.CACHE_KEY_IMG) as string;
      const subKey = prefs.getValue(WbiSigner.CACHE_KEY_SUB) as string;
      const timeStr = prefs.getValue(WbiSigner.CACHE_KEY_TIME) as string;
      if (imgKey && subKey && timeStr) {
        return { imgKey, subKey, time: parseInt(timeStr) };
      }
    } catch (e) {
      Logger.error(TAG, 'Error reading WBI cache', e);
    }
    return null;
  }
}

export const wbiSigner = new WbiSigner();