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

import { BreakpointSystem } from '../common/utils/BreakpointSystem';
import Logger from '../common/utils/Logger';
import { MediaControlCenter } from '../common/utils/mediautils/MediaControlCenter';
import { PlayerInfoComponent } from '../view/PlayerInfoComponent';

const TAG = 'Index';

@Entry
@Component
struct Index {
  @State isShowPlay: boolean = false;
  private breakpointSystem: BreakpointSystem = new BreakpointSystem();
  @State splashOpacity: number = 1.0;
  @State showSplash: boolean = true;
  private splashDuration: number = 1000;
  private animateDuration: number = 500;
  private splashTimer?: number;

  async aboutToAppear() {
    try {
      MediaControlCenter.getInstance().init();
      this.breakpointSystem.register();
    } catch (error) {
      Logger.error(TAG, `getInstance failed: ${error}`)
    }
  }

  aboutToDisappear(): void {
    clearTimeout(this.splashTimer);
    this.breakpointSystem.unregister();
    MediaControlCenter.getInstance().release();
  }

  build() {
    Stack() {
      PlayerInfoComponent({ isShowPlay: this.isShowPlay });
      if (this.showSplash) {
        Column() {
          Image($r('app.media.foreground'))
            .objectFit(ImageFit.Contain)
            .width("256vp")
          Row() {
            Text('Aurum')
              .fontSize(32)
              .fontWeight(FontWeight.Bold)
              .fontColor('#EAD5B2')
            Text('Music')
              .fontSize(32)
              .fontWeight(FontWeight.Lighter)
              .fontColor('#F3E6D8')
              .margin({ left: 8 })
          }
        }
        .width("100%")
        .height("100%")
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r("app.color.start_window_background"))
        .opacity(this.splashOpacity)
        .onAppear(() => {
          this.splashTimer = setTimeout(() => {
            this.getUIContext().animateTo({
              duration: this.animateDuration,
              curve: Curve.EaseOut,
              onFinish: () => {
                this.showSplash = false;
              }
            }, () => {
              this.splashOpacity = 0;
            });
          }, this.splashDuration);
        });
      }
    }
  }
}