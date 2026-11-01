// Build-time replacement for gptk's src/ui/logic/log: their progress lines become
// native progress events instead of DOM writes.
type LogHandler = { postMessage(message: unknown): void };
type WebKitWindow = { webkit?: { messageHandlers?: { cuePhotosLog?: LogHandler } } };

export default function log(logMessage: string, type: string | null = null): void {
  try {
    (window as unknown as WebKitWindow).webkit?.messageHandlers?.cuePhotosLog?.postMessage({
      message: logMessage,
      type: type ?? 'info',
    });
  } catch {
    // handler detached; console below still has it
  }
  console.log(`[cuephotos] ${logMessage}`);
}
