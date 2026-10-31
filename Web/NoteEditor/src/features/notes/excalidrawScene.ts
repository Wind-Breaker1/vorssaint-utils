import type { ExcalidrawInitialDataState } from '@excalidraw/excalidraw/types';

/** 解析并规范化 Excalidraw 场景，Station 笔记统一使用透明画布。 */
export function parseExcalidrawScene(value: string): ExcalidrawInitialDataState | null {
	try {
		const parsed: unknown = JSON.parse(value);
		if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) throw new Error('INVALID_SCENE');
		const scene = parsed as ExcalidrawInitialDataState;
        if (!Array.isArray(scene.elements) || scene.elements.some(element => !element || typeof element !== 'object' || typeof element.id !== 'string' || typeof element.type !== 'string')) return null;
        if (scene.files && (typeof scene.files !== 'object' || Array.isArray(scene.files))) return null;
		return {
			...scene,
			appState: { ...scene.appState, viewBackgroundColor: 'transparent' },
		};
	} catch {
		return null;
	}
}
