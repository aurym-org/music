/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { mediaquery } from '@kit.ArkUI';
import { APP_STORAGE_KEYS } from '../constants/AppStorageKeys';
import { BreakpointConstants } from '../constants/BreakpointConstants';
import Logger from './Logger';

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

  private safelyRemoveListener(
    name: string,
    listener: mediaquery.MediaQueryListener | undefined,
    callback: (result: mediaquery.MediaQueryResult) => void
  ): boolean {
    if (!listener) {
      return true;
    }
    try {
      listener.off('change', callback);
      return true;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn('BreakpointSystem', `Failed to detach ${name} listener: ${message}`);
      return false;
    }
  }

  public register(): void {
    if (this.smListener && this.mdListener && this.lgListener) {
      return;
    }
    this.unregister();
    if (this.smListener || this.mdListener || this.lgListener) {
      return;
    }

    const uiContext: UIContext | undefined = AppStorage.get(APP_STORAGE_KEYS.UI_CONTEXT) as UIContext | undefined;
    if (!uiContext) {
      return;
    }

    try {
      // Store each reference before registering its callback so a partial
      // registration failure can be rolled back by unregister().
      this.smListener = uiContext.getMediaQuery().matchMediaSync(BreakpointConstants.RANGE_SM);
      this.smListener.on('change', this.isBreakpointSM);
      this.mdListener = uiContext.getMediaQuery().matchMediaSync(BreakpointConstants.RANGE_MD);
      this.mdListener.on('change', this.isBreakpointMD);
      this.lgListener = uiContext.getMediaQuery().matchMediaSync(BreakpointConstants.RANGE_LG);
      this.lgListener.on('change', this.isBreakpointLG);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error('BreakpointSystem', `Breakpoint listener registration failed: ${message}`);
      this.unregister();
    }
  }

  public unregister(): void {
    // Clear each reference only after its listener is successfully detached.
    // A failed off() remains reachable for the next cleanup attempt.
    if (this.safelyRemoveListener('small', this.smListener, this.isBreakpointSM)) {
      this.smListener = undefined;
    }
    if (this.safelyRemoveListener('medium', this.mdListener, this.isBreakpointMD)) {
      this.mdListener = undefined;
    }
    if (this.safelyRemoveListener('large', this.lgListener, this.isBreakpointLG)) {
      this.lgListener = undefined;
    }
  }

}
