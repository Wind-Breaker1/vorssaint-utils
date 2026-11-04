

import { Component, useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { Excalidraw, getCommonBounds, serializeAsJSON } from '@excalidraw/excalidraw';
import type { AppState, ExcalidrawImperativeAPI, ExcalidrawInitialDataState } from '@excalidraw/excalidraw/types';
import { parseExcalidrawScene } from '@/features/notes/excalidrawScene';

type Props = { documentKey: string; value: string; active?: boolean; readonly?: boolean; onChange: (value: string) => void };

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
export function ExcalidrawCanvas({ documentKey, value, active = true, readonly = false, onChange }: Props): React.JSX.Element {
	const [ready, setReady] = useState(false);
	const containerRef = useRef<HTMLDivElement>(null);
	const activeRef = useRef(active);
	activeRef.current = active;
	const pendingSceneRef = useRef<string | null>(null);
	const [initial, setInitial] = useState<ExcalidrawInitialDataState | null>(() => parseExcalidrawScene(value));
    const savedFileIDs = useRef(new Set(Object.keys(initial?.files ?? {})));
    type ElementRevision = { id: string; version: number; versionNonce: number; isDeleted: boolean };
    const contentSignature = useRef<readonly ElementRevision[] | null>(null);
    const previousFiles = useRef<unknown>(null);
    useEffect(() => {
        const saved = (event: Event) => {
            const { id, files } = (event as CustomEvent<{ id: string; files: string[] }>).detail;
            if (id.toLowerCase() !== incomingRef.current.key.toLowerCase()) return;
            files.forEach(file => savedFileIDs.current.add(file));
        };
        window.addEventListener('drawing-saved', saved);
        return () => window.removeEventListener('drawing-saved', saved);
    }, []);
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
			if (sceneFrameRef.current !== null) cancelAnimationFrame(sceneFrameRef.current);
		};
	}, []);
	const replaceScene = useCallback(
		(nextValue: string): boolean => {
			const api = apiRef.current;
			if (!api || !initializedRef.current) return false;
			if (sceneFrameRef.current !== null) {
				cancelAnimationFrame(sceneFrameRef.current);
				sceneFrameRef.current = null;
			}
			pendingSceneRef.current = nextValue;
			const width = containerRef.current?.clientWidth ?? 0;
			const height = containerRef.current?.clientHeight ?? 0;
			// A retained hidden canvas can report stale API dimensions. Wait for
			// visible layout instead of fitting into a zero-sized viewport.
			if (!activeRef.current || width <= 0 || height <= 0) {
				setReady(false);
				return false;
			}
			const scene = parseExcalidrawScene(nextValue);
			if (!scene) return false;
			pendingSceneRef.current = null;
			previousValueRef.current = { key: incomingRef.current.key, value: nextValue, active: true };
            // Hide before resetting the reused canvas: React state updates and
            // Excalidraw's RAF canvas paint do not commit at the same time.
            setReady(false);
            savedFileIDs.current = new Set(Object.keys(scene.files ?? {}));
            contentSignature.current = null;
			replacingSceneRef.current = true;
			initialChangeRef.current = true;
			// resetScene clears the internal store snapshot as well as undo/redo history.
			api.resetScene();
			const elements = (scene.elements ?? []).filter(element => !element.isDeleted);
            const [x1, y1, x2, y2] = getCommonBounds(elements);
            // Opening a wide scene may need less than Excalidraw's normal 10% toolbar limit.
            const zoom = elements.length ? Math.max(1e-9, Math.min(1, Math.max(width / 2, width - 80) / Math.max(1, x2 - x1), Math.max(height / 2, height - 180) / Math.max(1, y2 - y1))) : 1;
            // Install content and viewport together, before the next canvas paint.
            api.updateScene({ elements: scene.elements ?? [], appState: {
                ...scene.appState,
                width,
                height,
                zoom: { value: zoom as AppState['zoom']['value'] },
                scrollX: elements.length ? width / (2 * zoom) - (x1 + x2) / 2 : 0,
                scrollY: elements.length ? (height / 2 + 20) / zoom - (y1 + y2) / 2 : 0,
            } as AppState, captureUpdate: 'NEVER' });
			api.history.clear();
			if (scene.files) api.addFiles(Object.values(scene.files));
            scheduleSceneFrame(() => scheduleSceneFrame(() => {
                contentSignature.current = api.getSceneElements().map(({id, version, versionNonce, isDeleted}) => ({id, version, versionNonce, isDeleted}));
                initialChangeRef.current = false;
                replacingSceneRef.current = false;
                setReady(true);
                setInitial(previous => previous ? { elements: [] } : null);
            }));
			return true;
		},
		[scheduleSceneFrame],
	);
	useEffect(() => {
		const container = containerRef.current;
		if (!container) return;
		const observer = new ResizeObserver(() => {
			if (pendingSceneRef.current !== null && activeRef.current) {
				replaceScene(incomingRef.current.value);
			}
		});
		observer.observe(container);
		return () => observer.disconnect();
	}, [replaceScene]);
	const previousValueRef = useRef({ key: documentKey, value, active });
	useLayoutEffect(() => {
		if (!active) {
			previousValueRef.current.active = false;
			return;
		}
		if (previousValueRef.current.key === documentKey && previousValueRef.current.value === value && previousValueRef.current.active) return;
		const sameDocument = previousValueRef.current.key === documentKey;
		if (sameDocument && emittedValueRef.current === value) {
			emittedValueRef.current = null;
			previousValueRef.current = { key: documentKey, value, active };
		} else if (replaceScene(value)) {
			emittedValueRef.current = null;
			previousValueRef.current = { key: documentKey, value, active };
		}
	}, [documentKey, replaceScene, value, ready, active]);
	const handleChange = useCallback(
		(
			elements: Parameters<NonNullable<React.ComponentProps<typeof Excalidraw>['onChange']>>[0],
			appState: Parameters<NonNullable<React.ComponentProps<typeof Excalidraw>['onChange']>>[1],
			files: Parameters<NonNullable<React.ComponentProps<typeof Excalidraw>['onChange']>>[2],
		) => {
            if (!initializedRef.current) {
                if (appState.isLoading || !apiRef.current) return;
                initializedRef.current = true;
                replaceScene(incomingRef.current.value);
                return;
            }
			if (!activeRef.current) return;
			if (
				readonlyRef.current ||
				replacingSceneRef.current ||
				previousValueRef.current.key !== incomingRef.current.key ||
				previousValueRef.current.value !== incomingRef.current.value
			)
				return;
            // Viewport and selection callbacks are not document edits.
            const previous = contentSignature.current;
            const sameElements = previous?.length === elements.length && elements.every((element, index) => {
                const old = previous[index];
                return old.id === element.id && old.version === element.version && old.versionNonce === element.versionNonce && old.isDeleted === element.isDeleted;
            });
            const newFiles = files !== previousFiles.current && Object.keys(files).some(id => !savedFileIDs.current.has(id));
            previousFiles.current = files;
            if (!initializedRef.current || initialChangeRef.current || contentSignature.current === null) {
                contentSignature.current = elements.map(({id, version, versionNonce, isDeleted}) => ({id, version, versionNonce, isDeleted}));
                initialChangeRef.current = false;
                return;
            }
            if (sameElements && !newFiles) return;
            contentSignature.current = elements.map(({id, version, versionNonce, isDeleted}) => ({id, version, versionNonce, isDeleted}));
            const scene = JSON.parse(serializeAsJSON(elements, appState, files, 'database'));
            scene.files = Object.fromEntries(Object.entries(files).filter(([id]) => !savedFileIDs.current.has(id)));
            const next = JSON.stringify(scene);
			if (next !== sourceRef.current) {
				emittedValueRef.current = next;
                sourceRef.current = next;
				onChangeRef.current(next);
			}
		},
		[replaceScene],
	);
    const attachAPI = useCallback((api: ExcalidrawImperativeAPI) => { apiRef.current = api; }, []);
	if (!initial)
		return (
			<div className="flex min-h-0 flex-1 items-center justify-center p-6 text-center text-xs text-station-danger">
				画布数据无效，无法打开。
			</div>
		);
	return (
		<ExcalidrawErrorBoundary>
			<div ref={containerRef} className="excalidraw-canvas min-h-0 flex-1 overflow-hidden" data-ready={ready ? 'true' : 'false'}>
				<Excalidraw
					initialData={initial}
					viewModeEnabled={readonly}
					theme="dark"
                    langCode="zh-CN"
					UIOptions={{ canvasActions: { loadScene: false, export: false, saveToActiveFile: false } }}
                    excalidrawAPI={attachAPI}
					onChange={handleChange}
				/>

            </div>
        </ExcalidrawErrorBoundary>
	);
}
