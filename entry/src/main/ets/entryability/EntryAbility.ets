/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import Logger from '../common/utils/Logger';
import { display, window } from '@kit.ArkUI';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { HiAppEventManager } from '../common/utils/HiAppEventManager';
import { APP_STORAGE_KEYS } from '../common/constants/AppStorageKeys';
import { MediaControlCenter } from '../common/utils/mediautils/MediaControlCenter';

const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private windowObj?: window.Window;
  private windowStageGeneration: number = 0;
  private readonly onWindowSizeChange = (windowSize: window.Size): void => {
    this.updateBreakpoint(windowSize.width);
  };

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    HiAppEventManager.configure();
    try {
      AppStorage.setOrCreate(APP_STORAGE_KEYS.CONTEXT, this.context);
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `Failed to set color mode: ${message}`);
    }
    Logger.info(TAG, 'Ability created');
  }

  onDestroy(): void {
    // Final fallback cleanup; Index.aboutToDisappear normally releases these
    // resources first, but Ability destruction must remain safe and idempotent.
    MediaControlCenter.getInstance().release();
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CONTEXT, undefined);
    Logger.info(TAG, 'Ability destroyed');
  }

  private updateBreakpoint(windowWidth: number): void {
    const windowWidthVp = windowWidth / display.getDefaultDisplaySync().densityPixels;
    let curBp: string = BreakpointConstants.BREAKPOINT_LG;
    if (windowWidthVp < BreakpointConstants.BREAKPOINT_VALUE_NUMBER[1]) {
      curBp = BreakpointConstants.BREAKPOINT_SM;
    } else if (windowWidthVp < BreakpointConstants.BREAKPOINT_VALUE_NUMBER[2]) {
      curBp = BreakpointConstants.BREAKPOINT_MD;
    } else {
      curBp = BreakpointConstants.BREAKPOINT_LG;
    }
    AppStorage.setOrCreate(BreakpointConstants.CURRENT_BREAKPOINT, curBp);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability.
    const generation = ++this.windowStageGeneration;
    Logger.info(TAG, 'Window stage created');

    windowStage.loadContent('pages/Index', (err) => {
      if (generation !== this.windowStageGeneration) {
        return;
      }
      if (err.code) {
        Logger.error(TAG, `Failed to load page content: ${err.code} ${err.message}`);
        return;
      }
      AppStorage.setOrCreate(APP_STORAGE_KEYS.WINDOW_STAGE, windowStage);
      windowStage.getMainWindow().then((mainWindow: window.Window) => {
        if (generation !== this.windowStageGeneration) {
          return;
        }
        this.windowObj = mainWindow;
        AppStorage.setOrCreate<window.Window>(APP_STORAGE_KEYS.WINDOW, mainWindow);
        mainWindow.setWindowLayoutFullScreen(true);
        const uiContext = mainWindow.getUIContext();
        AppStorage.setOrCreate(APP_STORAGE_KEYS.UI_CONTEXT, uiContext);
        const topArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const bottomArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        const topHeight = topArea ? uiContext.px2vp(topArea.topRect.height) : 0;
        const bottomHeight = bottomArea ? uiContext.px2vp(bottomArea.bottomRect.height) : 0;
        AppStorage.setOrCreate(APP_STORAGE_KEYS.TOP_HEIGHT, topHeight);
        AppStorage.setOrCreate(APP_STORAGE_KEYS.BOTTOM_HEIGHT, bottomHeight);
        this.updateBreakpoint(mainWindow.getWindowProperties().windowRect.width);
        mainWindow.on('windowSizeChange', this.onWindowSizeChange);
      }).catch((error: Error) => {
        Logger.error(TAG, `Failed to get main window: ${error.message}`);
      });
      Logger.info(TAG, 'Page content loaded');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources.
    this.windowStageGeneration++;
    this.windowObj?.off('windowSizeChange', this.onWindowSizeChange);
    this.windowObj = undefined;
    AppStorage.setOrCreate(APP_STORAGE_KEYS.WINDOW, undefined);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.WINDOW_STAGE, undefined);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.UI_CONTEXT, undefined);
    Logger.info(TAG, 'Window stage destroyed');
  }

  onForeground(): void {
    // Ability has brought to foreground
    Logger.info(TAG, 'Ability foreground');
  }

  onBackground(): void {
    // Ability has back to background
    Logger.info(TAG, 'Ability background');
  }
}
