/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
// [Start media_tools]
import { util } from '@kit.ArkTS';
import Logger from '../Logger';
import { SECOND_BUFFER_WALK } from '../../constants/PlayerConstants';

// [StartExclude media_tools]

const TAG = 'MediaTools';
// [EndExclude media_tools]
export class MediaTools {
  // [StartExclude media_tools]
  static async getPixelMapFromResource(context: common.UIAbilityContext,
    name: resourceManager.Resource): Promise<PixelMap> {
    let resourceMgr = context.resourceManager;
    let fileData: Uint8Array = await resourceMgr.getMediaContent(name.id);
    return await image.createImageSource(fileData.buffer as ArrayBuffer).createPixelMap();
  }

  static async getPixelMapFromFile(id: string, path: string): Promise<image.PixelMap> {
    Logger.info(TAG, 'getPixelMapFromFile id:' + id + ', path:' + path);
    return await image.createImageSource(path).createPixelMap();
  }

  /**
   * @param {string} value - Data value
   * @return {string} - If the date is less than two digits, add 0
   */
  private static fill(value: number): string {
    return value.toString().padStart(2, '0');
  }

  static msToCountdownTime(ms: number): string {
    if (!ms) {
      return '00:00';
    }
    const days = Math.floor(ms / (1000 * 60 * 60 * 24));
    const hours = Math.floor((ms % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
    const minutes = Math.floor((ms % (1000 * 60 * 60)) / (1000 * 60));
    const seconds = Math.floor((ms % (1000 * 60)) / 1000);
    return `${(days ? MediaTools.fill(days) + ':' : '')}${(hours ? MediaTools.fill(hours) + ':' : '')}
      ${MediaTools.fill(minutes)}:${MediaTools.fill(seconds)} `.trim();
  }

  // Convert bytes to seconds
  static getMsFromByteLength(byteLength: number): number {
    return 1000 * (byteLength / SECOND_BUFFER_WALK);
  }

  static getOffsetFromTime(curMs: number) {
    return (curMs / 1000) * SECOND_BUFFER_WALK;
  }
  // [EndExclude media_tools]
  static async getLrcFromRawFile(context: common.UIAbilityContext, filename: string): Promise<string | undefined> {
    if (!filename) {
      return undefined;
    }
    const lyricUint8Array: Uint8Array = await context.resourceManager.getRawFileContent(filename);
    let textDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    let resStr: string = textDecoder.decodeToString(lyricUint8Array, { stream: false });
    return resStr;
  }
}
// [End media_tools]