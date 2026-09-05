/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { display } from '@kit.ArkUI';
import { MusicInfoComponent } from './MusicInfoComponent';
import { ControlAreaComponent } from './ControlAreaComponent';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { SongItem } from '../viewmodel/SongData';
import Logger from '../common/utils/Logger';
import { APP_STORAGE_KEYS } from '../common/constants/AppStorageKeys';

const TAG = 'PlayerInfoComponent'

@Component
export struct PlayerInfoComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageLink(APP_STORAGE_KEYS.SONG_LIST) songList: SongItem[] = [];
  @StorageProp(APP_STORAGE_KEYS.SELECT_INDEX) selectIndex: number = 0;
  @StorageLink(APP_STORAGE_KEYS.TOP_HEIGHT) topHeight: number = 0;
  @StorageLink(APP_STORAGE_KEYS.BOTTOM_HEIGHT) bottomHeight: number = 0;
  @Link isShowPlay: boolean;
  @StorageLink(APP_STORAGE_KEYS.IS_FOLD_FULL) isFoldFull: boolean = false;
  @StorageLink(APP_STORAGE_KEYS.CURRENT_PIXEL_MAP) currentPixelMap: PixelMap | undefined = undefined;

  private callback: Callback<display.FoldDisplayMode> = (data: display.FoldDisplayMode) => {
    if (canIUse('SystemCapability.Window.SessionManager')) {
      if (data === display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL) {
        this.isFoldFull = true;
      } else {
        this.isFoldFull = false;
      }
    }
  };

  aboutToAppear(): void {
    Logger.info(TAG, `currentBreakpoint is ${BreakpointConstants.BREAKPOINT_SM}`)
    try {
      if (canIUse('SystemCapability.Window.SessionManager')) {
        let mode = display.getFoldDisplayMode();
        if (mode === display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL) {
          this.isFoldFull = true;
        }
        display.on('foldDisplayModeChange', this.callback);
      }
    } catch (exception) {
      Logger.error(TAG, `Failed to register callback. Code: ' + ${JSON.stringify(exception)}`);
    }
  }

  aboutToDisappear(): void {
    if (canIUse('SystemCapability.Window.SessionManager')) {
      display.off('foldDisplayModeChange', this.callback);
    }
  }

  build() {
    Stack() {
      Image(this.currentPixelMap)
        .size(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG ?
          {
            width: PlayerConstants.BACK_IMAGE
          } :
          {
            height: PlayerConstants.BACK_IMAGE
          })
        .aspectRatio(1)
        .objectFit(ImageFit.Cover)
        .opacity(0.5)
        .blur(PlayerConstants.IMAGE_BLUR)
      Row() {
        if (this.isFoldFull) {
          Column() {
            MusicInfoComponent()
              .margin({
                left: $r('app.float.margin_small'),
                right: $r('app.float.margin_small')
              })
          }
          .layoutWeight(1)
          .padding({
            left: $r('app.float.common_padding'),
            right: $r('app.float.common_padding')
          })
          .margin({
            bottom: $r('app.float.fold_margin_bottom')
          })
        } else if (this.currentBreakpoint === BreakpointConstants.BREAKPOINT_LG) {
          Column() {
            Column() {
              Image(this.currentPixelMap)
                .width(StyleConstants.FULL_WIDTH)
                .aspectRatio(1)
                .borderRadius($r('app.float.cover_radius'))
              ControlAreaComponent()
            }
            .height(StyleConstants.FULL_HEIGHT)
            .justifyContent(FlexAlign.SpaceBetween)
            .margin({
              bottom: $r('app.float.common_margin')
            })
          }
          .layoutWeight(1)
          .padding({
            left: $r('app.float.common_padding'),
            right: $r('app.float.common_padding'),
            top: $r('app.float.lg_music_top'),
            bottom: $r('app.float.lg_music_margin_bottom')
          })
        } else {
          Column() {
            MusicInfoComponent()
              .margin({
                left: $r('app.float.margin_small'),
                right: $r('app.float.margin_small'),
                top: $r('app.float.music_component_top'),
                bottom: $r('app.float.music_component_bottom')
              })
          }
          .layoutWeight(1)
          .padding({
            left: $r('app.float.common_padding'),
            right: $r('app.float.common_padding')
          })
          .margin({
            bottom: $r('app.float.fold_margin_bottom')
          })
        }
      }
      .padding({
        bottom: this.bottomHeight,
        top: this.topHeight
      })
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_WIDTH)
    .background(Color.Black)
  }
}