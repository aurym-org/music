/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { NetworkDiagnostics } from './NetworkDiagnostics';

/** Owns the HTTP stream and sequential asynchronous writes for one file. */
export class MediaDownloadWriter {
  private static readonly MAX_RESPONSE_BYTES: number = 100 * 1024 * 1024;
  private static readonly CONNECT_TIMEOUT_MS: number = 15000;
  private static readonly READ_TIMEOUT_MS: number = 60000;
  private static readonly MAX_REDIRECTS: number = 5;

  public static async download(
    url: string,
    headers: Record<string, string>,
    path: string,
    isCurrent: () => boolean,
    onCancelAvailable: (cancel: (() => void) | undefined) => void
  ): Promise<void> {
    const request = http.createHttp();
    let requestDestroyed = false;
    const destroyRequest = (): void => {
      if (!requestDestroyed) {
        requestDestroyed = true;
        request.destroy();
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
    let writeError: Error | undefined;
    let cancelled = false;
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

    onCancelAvailable(cancelDownload);

    const onDataReceive = (chunk: ArrayBuffer): void => {
      if (cancelled || writeError) {
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
      resolveDataEnd();
    };

    try {
      request.on('dataReceive', onDataReceive);
      request.on('dataEnd', onDataEnd);
      try {
        responseCode = await request.requestInStream(url, {
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
      throw new Error(error.message);
    } finally {
      request.off('dataReceive', onDataReceive);
      request.off('dataEnd', onDataEnd);
      if (!isCurrent()) {
        cancelDownload();
      }
      onCancelAvailable(undefined);
      destroyRequest();
      await writeQueue;
      fileIo.closeSync(file);
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
