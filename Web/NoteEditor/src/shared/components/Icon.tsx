import type { SVGProps } from 'react';

export type IconName =
	| 'home'
	| 'tasks'
	| 'lightbulb'
	| 'projects'
	| 'notes'
	| 'quote'
	| 'excalidraw'
	| 'settings'
	| 'recycle'
	| 'clipboard'
	| 'images'
	| 'domains'
	| 'search'
	| 'trash'
	| 'calendar'
	| 'chevron-left'
	| 'chevron-down'
	| 'chevron-right'
	| 'double-chevron-left'
	| 'double-chevron-right'
	| 'collapse-all'
	| 'expand-all'
	| 'plus'
	| 'edit'
	| 'save'
	| 'pause'
	| 'play'
	| 'focus'
	| 'focus-exit'
	| 'download'
	| 'preview'
	| 'close'
	| 'property-text'
	| 'property-number'
	| 'property-checkbox'
	| 'property-date'
	| 'property-list'
	| 'info'
	| 'warning'
	| 'danger'
	| 'wallet';

export function Icon({ name, className = '', ...props }: SVGProps<SVGSVGElement> & { name: IconName }): React.JSX.Element {
	return (
		<svg viewBox="0 0 24 24" className={`station-icon ${className}`.trim()} {...props}>
			{name === 'focus' && <path d="M8 3H3v5M16 3h5v5M3 16v5h5M21 16v5h-5M9 10h6M9 14h6" />}
			{name === 'focus-exit' && <path d="M3 8h5V3M21 8h-5V3M8 21v-5H3M16 21v-5h5M10 10h4M10 14h4" />}
			{name === 'pause' && <path d="M8 5v14M16 5v14" />}
			{name === 'play' && <path d="m8 5 11 7-11 7Z" />}
			{name === 'home' && (
				<>
					<path d="M3 11.5 12 4l9 7.5" />
					<path d="M5.5 10v10h13V10" />
				</>
			)}
			{name === 'tasks' && (
				<>
					<circle cx="12" cy="12" r="9" />
					<path d="m8 12 2.5 2.5L16 9" />
				</>
			)}
			{name === 'lightbulb' && (
				<>
					<path d="M9 18h6M10 21h4" />
					<path d="M8.5 14.5a7 7 0 1 1 7 0c-.9.65-1.5 1.5-1.5 2.5h-4c0-1-.6-1.85-1.5-2.5Z" />
					<path d="M12 3v1M4.9 5.9l.7.7M19.1 5.9l-.7.7" />
				</>
			)}
			{name === 'projects' && <path d="M3.5 6.5h6l2 2h9v10h-17z" />}
			{name === 'notes' && (
				<>
					<path d="M6 3.5h9l3 3v14H6z" />
					<path d="M9 11h6M9 15h6" />
				</>
			)}
			{name === 'quote' && (
				<>
					<path d="M7 8.5H4.5v4A3.5 3.5 0 0 0 8 16v-2.5H6.5V11H8V8.5Z" />
					<path d="M19.5 8.5H17v4a3.5 3.5 0 0 0 3.5 3.5v-2.5H19V11h1.5V8.5Z" />
				</>
			)}
			{name === 'wallet' && <path d="M4 7.5h14a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7.5h16M4 7.5V5h11l2 2.5M16 13h3" />}
			{name === 'excalidraw' && (
				<>
					<path d="M5 5h14v14H5z" />
					<path d="m8 16 7.7-7.7 2 2L10 18H8z" />
					<path d="m14.6 9.4 2 2" />
				</>
			)}
			{name === 'settings' && (
				<>
					<circle cx="12" cy="12" r="3" />
					<path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.5 1A8 8 0 0 0 15 6.2L14.7 3h-4L10.4 6A8 8 0 0 0 9 7.1l-2.5-1-2 3.4 2 1.5a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.5-1a8 8 0 0 0 1.4.9l.3 3.2h4l.3-3.2a8 8 0 0 0 1.4-.9l2.5 1 2-3.4-2-1.5c.1-.3.1-.7.1-1Z" />
				</>
			)}
			{name === 'recycle' && (
				// 循环箭头的绘制范围是 3..21（18×18），是整套图标里唯一在两个方向都撑满的，
				// 同尺寸下会显得偏大；以中心按 0.9 缩放，对齐到其余图标约 16×16 的视觉重量。
				<g transform="translate(12 12) scale(0.9) translate(-12 -12)">
					<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8" />
					<path d="M21 3v5h-5" />
					<path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16" />
					<path d="M8 16H3v5" />
				</g>
			)}
			{name === 'search' && (
				<>
					<circle cx="10.8" cy="10.8" r="6.8" />
					<path d="m16 16 4 4" />
				</>
			)}
			{name === 'trash' && <path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5" />}
			{name === 'clipboard' && (
				<>
					<rect x="5" y="4" width="14" height="17" rx="2" />
					<path d="M9 4.5V3h6v1.5M8 9h8M8 13h8M8 17h5" />
				</>
			)}
			{name === 'images' && (
				<>
					<rect x="4" y="5" width="16" height="14" rx="2" />
					<circle cx="9" cy="10" r="1.5" />
					<path d="m5 17 4-4 3 3 2-2 5 4" />
				</>
			)}
			{name === 'domains' && (
				<>
					<circle cx="12" cy="12" r="8.5" />
					<path d="M3.5 12h17M12 3.5c2.2 2.3 3.2 5.1 3.2 8.5S14.2 18.2 12 20.5M12 3.5C9.8 5.8 8.8 8.6 8.8 12s1 6.2 3.2 8.5" />
				</>
			)}
			{name === 'calendar' && (
				<>
					<rect x="4" y="5" width="16" height="15" rx="2" />
					<path d="M8 3v4M16 3v4M4 10h16" />
				</>
			)}
			{name === 'chevron-left' && <path d="m15 6-6 6 6 6" />}
			{name === 'chevron-down' && <path d="m6 9 6 6 6-6" />}
			{name === 'chevron-right' && <path d="m9 6 6 6-6 6" />}
			{name === 'double-chevron-left' && (
				<>
					<path d="m13 6-6 6 6 6" />
					<path d="m19 6-6 6 6 6" />
				</>
			)}
			{name === 'double-chevron-right' && (
				<>
					<path d="m11 6 6 6-6 6" />
					<path d="m5 6 6 6-6 6" />
				</>
			)}
			{name === 'collapse-all' && (
				<>
					<path d="m6 4 6 6 6-6" />
					<path d="m6 20 6-6 6 6" />
				</>
			)}
			{name === 'expand-all' && (
				<>
					<path d="m6 10 6-6 6 6" />
					<path d="m6 14 6 6 6-6" />
				</>
			)}
			{name === 'plus' && <path d="M12 5v14M5 12h14" />}
			{name === 'edit' && <path d="m5 19 1.4-4.2L16.8 4.4a1.8 1.8 0 0 1 2.6 2.6L9 17.4 5 19Z" />}
			{name === 'save' && (
				<>
					<path d="M5 4h12l3 3v13H5z" />
					<path d="M8 4v6h8V4M8 20v-6h8v6" />
				</>
			)}
			{name === 'download' && <path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5" />}
			{name === 'preview' && (
				<>
					<path d="M3.5 12s3-5 8.5-5 8.5 5 8.5 5-3 5-8.5 5-8.5-5-8.5-5Z" />
					<circle cx="12" cy="12" r="2" />
				</>
			)}
			{name === 'close' && <path d="m7 7 10 10M17 7 7 17" />}
			{name === 'property-text' && <path d="M5 6h14M5 12h14M5 18h9" />}
			{name === 'property-number' && (
				<>
					<path d="M7 5 5 19M13 5l-2 14M4 10h10M3 15h10" />
					<path d="M17 8h3l-3 4h3M17 18h3" />
				</>
			)}
			{name === 'property-checkbox' && (
				<>
					<rect x="4" y="4" width="16" height="16" rx="3" />
					<path d="m8 12 2.5 2.5L16 9" />
				</>
			)}
			{name === 'property-date' && (
				<>
					<rect x="4" y="5" width="16" height="15" rx="2" />
					<path d="M8 3v4M16 3v4M4 10h16M8 14h.01M12 14h.01M16 14h.01" />
				</>
			)}
			{name === 'property-list' && <path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01" />}
			{name === 'info' && (
				<>
					<circle cx="12" cy="12" r="9" />
					<path d="M12 11v5M12 8h.01" />
				</>
			)}
			{name === 'warning' && (
				<>
					<path d="M12 4 3 20h18L12 4Z" />
					<path d="M12 10v4M12 17h.01" />
				</>
			)}
			{name === 'danger' && (
				<>
					<circle cx="12" cy="12" r="9" />
					<path d="M12 7v5M12 16h.01" />
				</>
			)}
		</svg>
	);
}
