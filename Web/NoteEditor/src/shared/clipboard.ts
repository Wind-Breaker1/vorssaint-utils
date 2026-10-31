type ClipboardBridge = { postMessage: (message: object) => Promise<unknown> };

function nativeClipboard(): ClipboardBridge | undefined {
    return (window as any).webkit?.messageHandlers.noteClipboard;
}

/** WKWebView 的本地页面通过 AppKit 读写；浏览器开发环境沿用标准 API。 */
export async function readClipboardText(): Promise<string> {
    const bridge = nativeClipboard();
    if (!bridge) return navigator.clipboard.readText();
    const value = await bridge.postMessage({ action: 'read' });
    if (typeof value !== 'string') throw new Error('剪贴板返回内容无效');
    return value;
}

export async function writeClipboardText(text: string): Promise<void> {
    const bridge = nativeClipboard();
    if (!bridge) return navigator.clipboard.writeText(text);
    if (await bridge.postMessage({ action: 'write', text }) !== true) {
        throw new Error('无法写入剪贴板');
    }
}
