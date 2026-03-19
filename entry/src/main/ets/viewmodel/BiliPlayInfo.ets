/**
 * Bilibili 视频播放信息（__playinfo__）类型定义
 */
export interface BiliPlayInfo {
  code: number;
  message: string;
  ttl: number;
  data: PlayInfoData;
  session: string;
}

export interface PlayInfoData {
  from: string;
  result: string;
  message: string;
  quality: number;
  format: string;
  timelength: number;
  accept_format: string;
  accept_description: string[];
  accept_quality: number[];
  video_codecid: number;
  seek_param: string;
  seek_type: string;
  dash: DashInfo;           // 可能不存在（如旧视频）
  durl?: DurlItem[];         // 非 dash 时使用
  support_formats: SupportFormat[];
  high_format: null;   // 具体未知，可能为 null
  volume: VolumeInfo;
  last_play_time: number;
  last_play_cid: number;
  view_info: null;
  play_conf: PlayConf;
  cur_language: string;
  cur_production_type: number;
  auto_qn_resp: AutoQnResp;
}

export interface DashInfo {
  duration: number;
  minBufferTime: number;
  min_buffer_time: number;
  video: DashVideo[];
  audio: DashAudio[];
  dolby: DolbyInfo;
  flac: null | FlacInfo;
}

export interface DashVideo {
  id: number;                 // 视频清晰度 id，如 80,64,32,16
  baseUrl: string;
  base_url: string;
  backupUrl: string[];
  backup_url: string[];
  bandwidth: number;
  mimeType: string;
  mime_type: string;
  codecs: string;
  width: number;
  height: number;
  frameRate: string;
  frame_rate: string;
  sar: string;
  startWithSap: number;
  start_with_sap: number;
  SegmentBase: SegmentBase;
  segment_base: SegmentBase;
  codecid: number;
}

export interface DashAudio {
  id: number;                 // 音频码率 id，如 30280,30232,30216
  baseUrl: string;
  base_url: string;
  backupUrl: string[];
  backup_url: string[];
  bandwidth: number;
  mimeType: string;
  mime_type: string;
  codecs: string;
  width: number;              // 音频通常为 0
  height: number;             // 音频通常为 0
  frameRate: string;          // 音频通常为空字符串
  frame_rate: string;
  sar: string;
  startWithSap: number;
  start_with_sap: number;
  SegmentBase: SegmentBase;
  segment_base: SegmentBase;
  codecid: number;
}

export interface SegmentBase {
  Initialization: string;
  indexRange: string;
  initialization?: string;    // 部分字段是下划线形式
  index_range?: string;
}

export interface DolbyInfo {
  type: number;
  audio: null;        // 具体取决于是否包含杜比音频
}

export interface FlacInfo {
  // 如果有 flac 音频，可定义具体字段，示例中为 null
}

export interface DurlItem {
  order: number;
  length: number;
  size: number;
  ahead: string;
  vhead: string;
  url: string;
  backup_url: string[];
}

export interface SupportFormat {
  quality: number;
  format: string;
  new_description: string;
  display_desc: string;
  superscript: string;
  codecs: string[];
  can_watch_qn_reason: number;
  limit_watch_reason: number;
  report: Record<string, string>;
}

interface GeneratedTypeLiteralInterface_1 {
  high_dynamic_target_i: string;
  normal_target_i: string;
  undersized_target_i: string;
}

export interface VolumeInfo {
  measured_i: number;
  measured_lra: number;
  measured_tp: number;
  measured_threshold: number;
  target_offset: number;
  target_i: number;
  target_tp: number;
  multi_scene_args: GeneratedTypeLiteralInterface_1;
}

export interface PlayConf {
  is_new_description: boolean;
}

export interface AutoQnResp {
  dyeid: string;
}