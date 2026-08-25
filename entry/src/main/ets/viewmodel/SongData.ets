/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

/**
 * Music information entity class.
 */
export class SongItem {
  /**
   * Primary key ID.
   */
  id: number = 0;
  /**
   * Music name.
   */
  title: string = '';
  /**
   * Music author name.
   */
  singer: string = '';
  /**
   * Music avatar information.
   */
  label: string = '';
  /**
   * Music file path information.
   */
  src: string = '';
  /**
   * Index of the current music list.
   */
  index: number = 0;
  /**
   * bvid in BiliBili.
   */
  bvid: string = '';
  /**
   * cid in BiliBili.
   */
  cid: number = 0;
}
