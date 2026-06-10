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

const TAG = 'VolumeControl';

@Component
export struct VolumeControl {
  @StorageLink('isSilentMode') isSilentMode: boolean = false;
  @StorageLink('currentVolume') volume: number = 0;
  @StorageProp('currentBreakpoint') currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @State isShowSheet: boolean = false;

  getVolumeSymbol(): Resource {
    if (this.isSilentMode || this.volume === 0) {
      return $r('sys.symbol.speaker_wave_3_slash');
    }
    if (this.volume > 66) {
      return $r('sys.symbol.speaker_wave_3');
    } else if (this.volume > 33) {
      return $r('sys.symbol.speaker_wave_2');
    } else {
      return $r('sys.symbol.speaker_wave_1');
    }
  }

  build() {
    SymbolGlyph(this.getVolumeSymbol())
      .fontSize(26)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      .fontColor([Color.White])
      .opacity(0.86)
      .onClick(() => {
        this.isShowSheet = true;
      })
      .bindSheet($$this.isShowSheet, this.volumeSheet(), {
        detents: [SheetSize.FIT_CONTENT],
        dragBar: false,
        showClose: false,
        preferType: SheetType.CENTER,
        onWillAppear: async () => {
          Logger.info(TAG, 'volume sheet appearing');
          try {
            if (this.isSilentMode) {
              this.volume = 0;
            } else {
              const currentVol = MediaControlCenter.getInstance().getVolume();
              if (currentVol !== this.volume) {
                this.volume = currentVol;
              }
              Logger.info(TAG, `current volume is ${this.volume}`);
            }
          } catch (error) {
            Logger.error(TAG, `failed to get volume: ${error}`);
          }
        },
        onWillDismiss: () => {
          this.isShowSheet = false;
        }
      })
  }

  @Builder
  volumeSheet() {
    Column() {
      this.volumeTitle()
      Row() {
        Slider({
          value: this.volume,
          min: 0,
          max: 100,
          step: 1,
          style: SliderStyle.OutSet
        })
          .showTips(false)
          .layoutWeight(1)
          .onChange((value: number, _mode: SliderChangeMode) => {
            this.volume = value;
            if (this.volume === 0) {
              this.isSilentMode = true;
            } else {
              this.isSilentMode = false;
            }
          })
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
  volumeTitle() {
    Row() {
      SymbolGlyph(this.getVolumeSymbol())
        .fontSize(26)
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        .fontColor([$r('sys.color.ohos_id_color_text_primary')])
      Text($r('app.string.volume_setting'))
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