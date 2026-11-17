/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { BusinessError } from '@kit.BasicServicesKit';
import Logger from './Logger';

export type NetworkOperation = 'wbi.nav' | 'favorite.resource.list' | 'player.playurl' | 'media.download';
export type NetworkFailureCategory =
  'transport_error' | 'http_error' | 'parse_error' | 'business_error' |
  'response_validation_error' | 'stream_or_write_error' | 'request_or_parse_error';

/**
 * Safe, low-cardinality network diagnostics.
 * Callers must pass a stable operation name (for example "player.playurl"),
 * never a full URL, request headers, cookies, tokens, user IDs or media IDs.
 */
export class NetworkDiagnostics {
  public static success(
    tag: string,
    operation: NetworkOperation,
    startedAt: number,
    statusCode: number,
    attempt: number = 1,
    bytesReceived?: number
  ): void {
    const durationMs = Math.max(0, Date.now() - startedAt);
    const bytesPart = bytesReceived === undefined ? '' : ` bytes=${bytesReceived}`;
    Logger.info(
      tag,
      `[network] operation=${operation} result=success http=${statusCode} durationMs=${durationMs} attempt=${attempt}${bytesPart}`
    );
  }

  public static failure(
    tag: string,
    operation: NetworkOperation,
    startedAt: number,
    category: NetworkFailureCategory,
    attempt: number = 1,
    statusCode?: number,
    businessCode?: number,
    systemCode?: number
  ): void {
    const durationMs = Math.max(0, Date.now() - startedAt);
    const statusPart = statusCode === undefined ? '' : ` http=${statusCode}`;
    const businessPart = businessCode === undefined ? '' : ` businessCode=${businessCode}`;
    const systemPart = systemCode === undefined ? '' : ` systemCode=${systemCode}`;
    Logger.warn(
      tag,
      `[network] operation=${operation} result=failure category=${category}${statusPart}${businessPart}${systemPart} durationMs=${durationMs} attempt=${attempt}`
    );
  }

  /** Extract only a numeric platform error code; never log arbitrary error text. */
  public static getSystemErrorCode(error: BusinessError): number | undefined {
    return error.code;
  }
}
