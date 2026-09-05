/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { StyleConstants } from '../common/constants/StyleConstants';
import { BreakpointType } from '../common/utils/BreakpointSystem';
import Logger from '../common/utils/Logger';
import { MediaControlCenter } from '../common/utils/mediautils/MediaControlCenter';

const TAG = 'SpeedControl';

@Component
export struct SpeedControl {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @State speed: number = 1;
  @State isShowSheet: boolean = false;

  build() {
    SymbolGlyph($r('sys.symbol.video_speed'))
      .fontSize(26)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      .fontColor([Color.White])
      .opacity(0.86)
      .onClick(() => {
        this.isShowSheet = true;
      })
      .bindSheet($$this.isShowSheet, this.speedSheet(), {
        detents: [SheetSize.FIT_CONTENT],
        dragBar: false,
        showClose: false,
        preferType: SheetType.CENTER,
        onWillAppear: () => {
          Logger.info(TAG, 'speed sheet appearing');
        },
        onWillDismiss: () => {
          this.isShowSheet = false;
        }
      })
  }

  @Builder
  speedSheet() {
    Column() {
      this.speedTitle()
      Row() {
        Slider({
          value: this.speed,
          min: 0.25,
          max: 2,
          step: 0.25,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .showTips(true, this.speed.toString())
          .showSteps(true)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.speed = value;
            MediaControlCenter.getInstance().setSpeed(this.speed);
            Logger.info(TAG, `speed changed: ${value}, mode: ${mode}`);
          })
        Text(this.speed.toString())
          .fontSize(15)
          .width(30)
      }
      .padding({ left: 15, right: 15 })
    }
    .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
    .padding({
      top: this.currentBreakpoint === BreakpointConstants.BREAKPOINT_SM ? 0 : $r('app.float.list_area_padding_top'),
      bottom: $r('app.float.list_area_padding_bottom')
    })
  }

  @Builder
  speedTitle() {
    Row() {
      SymbolGlyph($r('sys.symbol.video_speed'))
        .fontSize(26)
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        .fontColor([$r('sys.color.ohos_id_color_text_primary')])
      Text($r('app.string.speed_setting'))
        .padding({ left: $r('app.float.play_all_text_padding') })
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .fontSize(new BreakpointType({
          sm: $r('app.float.play_font_sm'),
          md: $r('app.float.play_font_md'),
          lg: $r('app.float.play_font_lg')
        }).getValue(this.currentBreakpoint))
    }
    .height($r('app.float.play_all_area_height'))
    .width(StyleConstants.FULL_WIDTH)
    .padding({
      left: $r('app.float.play_all_area_padding'),
      right: $r('app.float.play_all_area_padding')
    })
    .borderRadius({
      topRight: $r('app.float.play_all_border_radius'),
      topLeft: $r('app.float.play_all_border_radius')
    })
  }
}