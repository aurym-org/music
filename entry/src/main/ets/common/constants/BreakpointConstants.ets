/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

/**
 * Constants for breakpoint.
 */
export class BreakpointConstants {
  /**
   * Breakpoints that represent small device types.
   */
  static readonly BREAKPOINT_SM: string = 'sm';

  /**
   * Breakpoints that represent middle device types.
   */
  static readonly BREAKPOINT_MD: string = 'md';

  /**
   * Breakpoints that represent large device types.
   */
  static readonly BREAKPOINT_LG: string = 'lg';

  /**
   * The break point value.
   */
  static readonly BREAKPOINT_VALUE_NUMBER: Array<number> = [320, 600, 840];

  /**
   * The number of columns for SM device.
   */
  static readonly COLUMN_SM: number = 4;

  /**
   * The number of columns for MD device.
   */
  static readonly COLUMN_MD: number = 8;

  /**
   * The number of gutter X for device.
   */
  static readonly GUTTER_MUSIC_X: number = 24;

  /**
   * The number of span for SM device.
   */
  static readonly SPAN_SM: number = 4;

  /**
   * The number of span for MD device.
   */
  static readonly SPAN_MD: number = 6;

  /**
   * The number of offset for MD device.
   */
  static readonly OFFSET_MD: number = 1;

  /**
   * Current breakpoints that to query the device types.
   */
  static readonly CURRENT_BREAKPOINT: string = 'currentBreakpoint';

  /**
   * Range of the small device width.
   */
  static readonly RANGE_SM: string = '(320vp<=width<600vp)';

  /**
   * Range of the middle device width.
   */
  static readonly RANGE_MD: string = '(600vp<=width<840vp)';

  /**
   * Range of the large device width.
   */
  static readonly RANGE_LG: string = '(840vp<=width)';
}
