/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

/**
 * Constants for player area.
 */
export class PlayerConstants {
  /**
   * The value of font family.
   */
  static readonly FONT_FAMILY_BLACK: string = 'HarmonyHeiTi';
  /**
   * The value of font family.
   */
  static readonly FONT_FAMILY_BOLD: string = 'HarmonyHeiTi-Bold';
  /**
   * The value of back ground image width and height.
   */
  static readonly BACK_IMAGE: string = '120%';
  /**
   * Set the image blur level.
   */
  static readonly IMAGE_BLUR: number = 15;
}

export enum MusicPlayMode {
  SINGLE_CYCLE = 0,
  ORDER = 1,
  RANDOM = 2
}

export const PlayModeSwitchList = [MusicPlayMode.ORDER, MusicPlayMode.RANDOM, MusicPlayMode.SINGLE_CYCLE];

export const SILENT_ID = 'silentId';

export const VOLUME_ID = 'volumeId';

export const PLAY_MODE_ID = 'playModeId';

export const DEFAULT_VOLUME = 100;

