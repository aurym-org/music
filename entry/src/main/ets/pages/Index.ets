/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
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
  private splashDuration: number = 1700;
  private splashFadeOutDuration: number = 500;
  private splashTimer?: number;
  @State titleOpacity: number = 0;
  @State subtitleOpacity: number = 0;
  @State titleTranslateY: number = 8;
  @State subtitleTranslateY: number = 8;
  private textFadeInDuration: number = 350;
  private titleDelay: number = 150;
  private titleTimer?: number;
  private subtitleDelay: number = 500;
  private subtitleTimer?: number;

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
    clearTimeout(this.titleTimer);
    clearTimeout(this.subtitleTimer);
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
            .width("42%")
            .margin({ bottom: 24 })
          Text('Aurym')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor('#E8D5C4')
            .opacity(this.titleOpacity)
            .letterSpacing(6)
            .translate({ y: this.titleTranslateY })
          Text('Hi-Res Sound')
            .fontSize(12)
            .fontWeight(FontWeight.Lighter)
            .fontColor('#E8D5C4')
            .opacity(this.subtitleOpacity)
            .letterSpacing(4)
            .translate({ y: this.subtitleTranslateY })
            .margin({ top: 8 })
        }
        .width("100%")
        .height("100%")
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r("app.color.start_window_background"))
        .opacity(this.splashOpacity)
        .onAppear(() => {
          this.titleTimer = setTimeout(() => {
            this.getUIContext().animateTo({
              duration: this.textFadeInDuration,
              curve: Curve.EaseOut
            }, () => {
              this.titleOpacity = 0.85;
              this.titleTranslateY = 0;
            });
          }, this.titleDelay);
          this.subtitleTimer = setTimeout(() => {
            this.getUIContext().animateTo({
              duration: this.textFadeInDuration,
              curve: Curve.EaseOut
            }, () => {
              this.subtitleOpacity = 0.65;
              this.subtitleTranslateY = 0;
            });
          }, this.subtitleDelay);
          this.splashTimer = setTimeout(() => {
            this.getUIContext().animateTo({
              duration: this.splashFadeOutDuration,
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