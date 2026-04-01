/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { display } from '@kit.ArkUI';
import { MusicInfoComponent } from './MusicInfoComponent';
import { ControlAreaComponent } from './ControlAreaComponent';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { PlayerConstants } from '../common/constants/PlayerConstants';
import { SongItem } from '../viewmodel/SongData';
import Logger from '../common/utils/Logger';

const TAG = 'PlayerInfoComponent'

@Component
export struct PlayerInfoComponent {
  @StorageProp('currentBreakpoint') currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageLink('songList') songList: SongItem[] = [];
  @StorageProp('selectIndex') selectIndex: number = 0;
  @StorageLink('topHeight') topHeight: number = 0;
  @StorageLink('bottomHeight') bottomHeight: number = 0;
  @Link isShowPlay: boolean;
  @StorageLink('isFoldFull') isFoldFull: boolean = false;
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
      Image(this.songList[this.selectIndex]?.label)
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
              Image(this.songList[this.selectIndex].label)
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