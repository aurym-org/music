/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { mediaquery } from '@kit.ArkUI';
import { APP_STORAGE_KEYS } from '../constants/AppStorageKeys';
import { BreakpointConstants } from '../constants/BreakpointConstants';

declare interface BreakPointTypeOption<T> {
  sm?: T,
  md?: T,
  lg?: T
}

export class BreakpointType<T> {
  options: BreakPointTypeOption<T>;

  constructor(option: BreakPointTypeOption<T>) {
    this.options = option;
  }

  getValue(currentPoint: string): T {
    if (currentPoint === 'sm') {
      return this.options.sm as T;
    }
    else if (currentPoint === 'md') {
      return this.options.md as T;
    } else {
      return this.options.lg as T;
    }
  }
}

export class BreakpointSystem {
  private currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  private smListener: mediaquery.MediaQueryListener | undefined = undefined;
  private mdListener: mediaquery.MediaQueryListener | undefined = undefined;
  private lgListener: mediaquery.MediaQueryListener | undefined = undefined;

  private updateCurrentBreakpoint(breakpoint: string): void {
    if (this.currentBreakpoint !== breakpoint) {
      this.currentBreakpoint = breakpoint;
      AppStorage.setOrCreate<string>(BreakpointConstants.CURRENT_BREAKPOINT, this.currentBreakpoint);
    }
  }

  private isBreakpointSM = (mediaQueryResult: mediaquery.MediaQueryResult): void => {
    if (mediaQueryResult.matches) {
      this.updateCurrentBreakpoint(BreakpointConstants.BREAKPOINT_SM);
    }
  }
  private isBreakpointMD = (mediaQueryResult: mediaquery.MediaQueryResult): void => {
    if (mediaQueryResult.matches) {
      this.updateCurrentBreakpoint(BreakpointConstants.BREAKPOINT_MD);
    }
  }
  private isBreakpointLG = (mediaQueryResult: mediaquery.MediaQueryResult): void => {
    if (mediaQueryResult.matches) {
      this.updateCurrentBreakpoint(BreakpointConstants.BREAKPOINT_LG);
    }
  }

  public register(): void {
    if (this.smListener || this.mdListener || this.lgListener) {
      return;
    }
    const uiContext: UIContext | undefined = AppStorage.get(APP_STORAGE_KEYS.UI_CONTEXT) as UIContext | undefined;
    if (!uiContext) {
      return;
    }
    this.smListener = uiContext.getMediaQuery().matchMediaSync(BreakpointConstants.RANGE_SM);
    this.smListener.on('change', this.isBreakpointSM);
    this.mdListener = uiContext.getMediaQuery().matchMediaSync(BreakpointConstants.RANGE_MD);
    this.mdListener.on('change', this.isBreakpointMD);
    this.lgListener = uiContext.getMediaQuery().matchMediaSync(BreakpointConstants.RANGE_LG);
    this.lgListener.on('change', this.isBreakpointLG);

  }

  public unregister(): void {
    if (this.smListener) {
      this.smListener.off('change', this.isBreakpointSM);
    }
    if (this.mdListener) {
      this.mdListener.off('change', this.isBreakpointMD);
    }
    if (this.lgListener) {
      this.lgListener.off('change', this.isBreakpointLG);
    }
    this.smListener = undefined;
    this.mdListener = undefined;
    this.lgListener = undefined;
  }
}
