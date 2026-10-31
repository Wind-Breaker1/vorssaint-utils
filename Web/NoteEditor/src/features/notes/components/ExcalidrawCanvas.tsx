

import { Component, useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { Excalidraw, serializeAsJSON } from '@excalidraw/excalidraw';
import type { AppState, ExcalidrawImperativeAPI, ExcalidrawInitialDataState } from '@excalidraw/excalidraw/types';
import { parseExcalidrawScene } from '@/features/notes/excalidrawScene';

type Props = { documentKey: string; value: string; readonly?: boolean; onChange: (value: string) => void };

class ExcalidrawErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
	state = { error: null as Error | null };

	static getDerivedStateFromError(error: Error): { error: Error } {
		return { error };
	}

	render(): ReactNode {
		if (this.state.error)
			return (
				<div className="flex min-h-0 flex-1 items-center justify-center p-6 text-center text-xs text-station-danger">
					画布初始化失败：{this.state.error.message}
				</div>
			);
		return this.props.children;
	}
}
export function ExcalidrawCanvas({ documentKey, value, readonly = false, onChange }: Props): React.JSX.Element {
	const [ready, setReady] = useState(false);
	const [initial] = useState<ExcalidrawInitialDataState | null>(() => parseExcalidrawScene(value));
	const apiRef = useRef<ExcalidrawImperativeAPI | null>(null);
	const emittedValueRef = useRef<string | null>(null);
	const sourceRef = useRef(value);
	const onChangeRef = useRef(onChange);
	const readonlyRef = useRef(readonly);
	const initializedRef = useRef(false);
	const initialChangeRef = useRef(true);
	const replacingSceneRef = useRef(false);
	const incomingRef = useRef({ key: documentKey, value });
	incomingRef.current = { key: documentKey, value };
	const initializationFrameRef = useRef<number | null>(null);
	const sceneFrameRef = useRef<number | null>(null);
	sourceRef.current = value;
	onChangeRef.current = onChange;
	readonlyRef.current = readonly;
	const scheduleSceneFrame = useCallback((callback: () => void): void => {
		if (sceneFrameRef.current !== null) cancelAnimationFrame(sceneFrameRef.current);
		sceneFrameRef.current = requestAnimationFrame(() => {
			sceneFrameRef.current = null;
			callback();
		});
	}, []);
	useEffect(() => {
		return () => {
			if (initializationFrameRef.current !== null) cancelAnimationFrame(initializationFrameRef.current);
			if (sceneFrameRef.current !== null) cancelAnimationFrame(sceneFrameRef.current);
		};
	}, []);
	const replaceScene = useCallback(
		(nextValue: string): boolean => {
			const api = apiRef.current;
			const scene = parseExcalidrawScene(nextValue);
			if (!api || !scene) return false;
			replacingSceneRef.current = true;
			initialChangeRef.current = true;
			// resetScene clears the internal store snapshot as well as undo/redo history.
			api.resetScene();
			api.updateScene({ elements: scene.elements ?? [], appState: scene.appState as AppState, captureUpdate: 'NEVER' });
			api.history.clear();
			if (scene.files) api.addFiles(Object.values(scene.files));
			scheduleSceneFrame(() => {
				// updateScene 通常会触发一次同步 onChange；若当前版本没有触发，
				// 也不能让下一次真实编辑事件被误认为场景初始化回调。
				initialChangeRef.current = false;
				replacingSceneRef.current = false;
			});
			return true;
		},
		[scheduleSceneFrame],
	);
	const previousValueRef = useRef({ key: documentKey, value });
	useLayoutEffect(() => {
		if (previousValueRef.current.key === documentKey && previousValueRef.current.value === value) return;
		const sameDocument = previousValueRef.current.key === documentKey;
		if (sameDocument && emittedValueRef.current === value) {
			emittedValueRef.current = null;
			previousValueRef.current = { key: documentKey, value };
		} else if (replaceScene(value)) {
			emittedValueRef.current = null;
			previousValueRef.current = { key: documentKey, value };
		}
	}, [documentKey, replaceScene, value, ready]);
	const handleChange = useCallback(
		(
			elements: Parameters<NonNullable<React.ComponentProps<typeof Excalidraw>['onChange']>>[0],
			appState: Parameters<NonNullable<React.ComponentProps<typeof Excalidraw>['onChange']>>[1],
			files: Parameters<NonNullable<React.ComponentProps<typeof Excalidraw>['onChange']>>[2],
		) => {
			if (
				readonlyRef.current ||
				replacingSceneRef.current ||
				previousValueRef.current.key !== incomingRef.current.key ||
				previousValueRef.current.value !== incomingRef.current.value
			)
				return;
            const next = serializeAsJSON(elements, appState, files, 'database');
			// 预览模式完全不接收画布事件；Excalidraw 初始化时也会触发一次 onChange。
			if (!initializedRef.current) {
				// 某些版本会在初始化帧内回调，先同步内部快照但不通知外层草稿。
				sourceRef.current = next;
				initialChangeRef.current = false;
				return;
			}
			if (initialChangeRef.current) {
				// 初始化回调可能晚于 requestAnimationFrame，到这里仍然不能算作用户修改。
				sourceRef.current = next;
				initialChangeRef.current = false;
				return;
			}
			if (next !== sourceRef.current) {
				emittedValueRef.current = next;
                sourceRef.current = next;
				onChangeRef.current(next);
			}
		},
		[],
	);
	if (!initial)
		return (
			<div className="flex min-h-0 flex-1 items-center justify-center p-6 text-center text-xs text-station-danger">
				画布数据无效，无法打开。
			</div>
		);
	return (
		<ExcalidrawErrorBoundary>
			<div className="excalidraw-canvas min-h-0 flex-1 overflow-hidden" data-ready={ready ? 'true' : 'false'}>
				<Excalidraw
					initialData={initial}
					viewModeEnabled={readonly}
					theme="dark"
                    langCode="zh-CN"
					UIOptions={{ canvasActions: { loadScene: false, export: false, saveToActiveFile: false } }}
					excalidrawAPI={(api) => {
						apiRef.current = api;
						// 等待初始化帧结束后才接收用户真正的编辑事件，避免初始场景被误判为修改。
						initializationFrameRef.current = requestAnimationFrame(() => {
							// Excalidraw 会在首帧后继续异步绘制 canvas；多等四帧，确保切换时默认深色帧已经完成。
							initializationFrameRef.current = requestAnimationFrame(() => {
								initializationFrameRef.current = requestAnimationFrame(() => {
									initializationFrameRef.current = requestAnimationFrame(() => {
										initializationFrameRef.current = null;
										initializedRef.current = true;
										setReady(true);
									});
								});
							});
						});
					}}
					onChange={handleChange}
				/>

            </div>
        </ExcalidrawErrorBoundary>
	);
}
