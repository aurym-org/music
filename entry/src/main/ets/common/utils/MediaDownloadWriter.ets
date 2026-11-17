/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { NetworkDiagnostics } from './NetworkDiagnostics';
import Logger from './Logger';

const TAG = 'MediaDownloadWriter';

/** Owns the HTTP stream and sequential asynchronous writes for one file. */
export class MediaDownloadWriter {
  private static readonly MAX_RESPONSE_BYTES: number = 100 * 1024 * 1024;
  private static readonly CONNECT_TIMEOUT_MS: number = 15000;
  private static readonly READ_TIMEOUT_MS: number = 60000;
  private static readonly MAX_REDIRECTS: number = 5;

  private static safelyCleanup(actionName: string, action: () => void): void {
    try {
      action();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `Cleanup failed (${actionName}): ${message}`);
    }
  }

  public static async download(
    url: string,
    headers: Record<string, string>,
    path: string,
    isCurrent: () => boolean,
    onCancelAvailable: (cancel: (() => void) | undefined) => void
  ): Promise<void> {
    const normalizedUrl = typeof url === 'string' ? url.trim() : '';
    if (!/^https?:\/\/[^\s/?#]+(?:[/?#][^\s]*)?$/i.test(normalizedUrl)) {
      throw new Error('Invalid media download URL: expected an absolute HTTP(S) URL');
    }

    const request = http.createHttp();
    let requestDestroyed = false;
    const destroyRequest = (): void => {
      if (!requestDestroyed) {
        requestDestroyed = true;
        try {
          request.destroy();
        } catch {
          // Request teardown is best-effort and must not prevent file cleanup.
        }
      }
    };

    let file: fileIo.File;
    try {
      file = fileIo.openSync(
        path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
      );
    } catch (error) {
      destroyRequest();
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(message);
    }

    let receivedBytes = 0;
    const requestStartedAt = Date.now();
    let responseCode: number | undefined = undefined;
    let diagnosticLogged = false;
    let primaryError: Error | undefined;
    let writeError: Error | undefined;
    let cancelled = false;
    // Once finalization begins, late native data events must not enqueue writes
    // against a file descriptor that is about to be closed.
    let acceptingData = true;
    let resolveDataEnd: () => void = () => {};
    const dataEnd = new Promise<void>((resolve) => {
      resolveDataEnd = resolve;
    });
    let writeQueue: Promise<void> = Promise.resolve();
    const cancelDownload = (): void => {
      if (cancelled) {
        return;
      }
      cancelled = true;
      resolveDataEnd();
      destroyRequest();
    };

    const onDataReceive = (chunk: ArrayBuffer): void => {
      if (!acceptingData || cancelled || writeError) {
        return;
      }
      if (!isCurrent()) {
        cancelDownload();
        return;
      }
      if (chunk.byteLength === 0) {
        return;
      }

      if (receivedBytes + chunk.byteLength > MediaDownloadWriter.MAX_RESPONSE_BYTES) {
        writeError = new Error('Download response exceeds the configured size limit');
        resolveDataEnd();
        destroyRequest();
        return;
      }
      receivedBytes += chunk.byteLength;
      writeQueue = writeQueue.then(async () => {
        if (cancelled || writeError) {
          return;
        }
        if (!isCurrent()) {
          cancelDownload();
          return;
        }
        await MediaDownloadWriter.writeChunk(
          file.fd,
          chunk,
          () => cancelled || !isCurrent()
        );
      }).catch((error: Error) => {
        writeError = error instanceof Error ? error : new Error(String(error));
        resolveDataEnd();
        destroyRequest();
      });
    };
    const onDataEnd = (): void => {
      if (acceptingData) {
        resolveDataEnd();
      }
    };

    try {
      // Register cancellation ownership inside the protected region. If the
      // owner callback throws, the request and file still reach finally.
      onCancelAvailable(cancelDownload);
      request.on('dataReceive', onDataReceive);
      request.on('dataEnd', onDataEnd);
      try {
        responseCode = await request.requestInStream(normalizedUrl, {
          method: http.RequestMethod.GET,
          header: headers,
          connectTimeout: MediaDownloadWriter.CONNECT_TIMEOUT_MS,
          readTimeout: MediaDownloadWriter.READ_TIMEOUT_MS,
          maxLimit: MediaDownloadWriter.MAX_RESPONSE_BYTES,
          maxRedirects: MediaDownloadWriter.MAX_REDIRECTS
        });
      } catch (error) {
        if (writeError) {
          throw writeError;
        }
        if (cancelled || !isCurrent()) {
          cancelDownload();
          return;
        }
        NetworkDiagnostics.failure('MediaDownloadWriter', 'media.download', requestStartedAt, 'transport_error', 1, undefined, undefined, NetworkDiagnostics.getSystemErrorCode(error));
        diagnosticLogged = true;
        const message = error instanceof Error ? error.message : String(error);
        throw new Error(message);
      }

      if (!isCurrent()) {
        cancelDownload();
        return;
      }
      if (cancelled) {
        return;
      }
      if (responseCode !== 200) {
        NetworkDiagnostics.failure('MediaDownloadWriter', 'media.download', requestStartedAt, 'http_error', 1, responseCode);
        diagnosticLogged = true;
        throw new Error(`HTTP error: ${responseCode}`);
      }

      await dataEnd;
      await writeQueue;
      if (!isCurrent()) {
        cancelDownload();
        return;
      }
      if (cancelled) {
        return;
      }
      if (writeError) {
        throw writeError;
      }
      if (receivedBytes === 0) {
        throw new Error('Empty response body');
      }
      NetworkDiagnostics.success('MediaDownloadWriter', 'media.download', requestStartedAt, responseCode, 1, receivedBytes);
      diagnosticLogged = true;
    } catch (error) {
      if (!diagnosticLogged && !cancelled) {
        NetworkDiagnostics.failure('MediaDownloadWriter', 'media.download', requestStartedAt, 'stream_or_write_error', 1, responseCode);
      }
      primaryError = error instanceof Error ? error : new Error(String(error));
      throw primaryError;
    } finally {
      // Gate callbacks before attempting to detach them. A failed off() must
      // not allow a late data event to write into a closed descriptor.
      acceptingData = false;
      MediaDownloadWriter.safelyCleanup(
        'dataReceive listener',
        () => request.off('dataReceive', onDataReceive)
      );
      MediaDownloadWriter.safelyCleanup(
        'dataEnd listener',
        () => request.off('dataEnd', onDataEnd)
      );
      if (!isCurrent()) {
        cancelDownload();
      }
      MediaDownloadWriter.safelyCleanup('cancel callback', () => onCancelAvailable(undefined));
      destroyRequest();
      await writeQueue;
      try {
        fileIo.closeSync(file);
      } catch (closeError) {
        // Preserve the original download failure; report close failures only
        // when the transfer itself otherwise completed successfully.
        if (!primaryError && !cancelled) {
          const message = closeError instanceof Error ? closeError.message : String(closeError);
          throw new Error(`Failed to close downloaded media file: ${message}`);
        }
      }
    }
  }

  private static async writeChunk(
    fd: number,
    chunk: ArrayBuffer,
    shouldStop: () => boolean
  ): Promise<void> {
    let written = 0;
    while (written < chunk.byteLength) {
      if (shouldStop()) {
        return;
      }
      const count = await fileIo.write(fd, chunk.slice(written));
      if (count <= 0) {
        throw new Error('Write file failed: no bytes written');
      }
      written += count;
    }
  }
}
