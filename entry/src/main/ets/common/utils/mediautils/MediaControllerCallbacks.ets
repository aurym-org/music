/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { MusicPlayMode } from '../../constants/PlayerConstants';

export interface AVPlayerEventCallbacks {
  onProgress: (time: number) => void;
  shouldAutoPlayForLoad: (version: number) => boolean;
  onPlay: () => void;
  onPause: () => void;
  onPlayNext: () => void;
}

export interface AVSessionCommandCallbacks {
  play: () => void;
  pause: () => void;
  playNext: () => void;
  playPrevious: () => void;
  seek: (position: number) => void;
  setPlayMode: (mode: MusicPlayMode) => void;
}
