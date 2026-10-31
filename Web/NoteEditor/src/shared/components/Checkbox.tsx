type Props = {
	checked: boolean;
	onChange: (checked: boolean) => void;
	disabled?: boolean;
	className?: string;
	'aria-label'?: string;
};

/** Station 统一复选框，避免浏览器原生控件在不同平台产生不一致外观。 */
export function Checkbox({ checked, onChange, disabled = false, className = '', 'aria-label': ariaLabel }: Props): React.JSX.Element {
	// 原生 input 只承担无障碍和表单语义，视觉样式由相邻 span 统一绘制。
	return (
		<label
			className={`inline-flex select-none size-4 shrink-0 cursor-pointer items-center justify-center ${disabled ? 'cursor-not-allowed opacity-50' : ''} ${className}`}
		>
			<input
				type="checkbox"
				checked={checked}
				aria-label={ariaLabel}
				disabled={disabled}
				className="peer sr-only"
				onChange={(event) => onChange(event.target.checked)}
			/>
			<span className="grid size-4 place-items-center rounded-xl border border-white/25 bg-white/5 text-white transition-all duration-150 active:scale-90 peer-checked:border-station-accent peer-checked:bg-station-accent peer-focus-visible:ring-2 peer-focus-visible:ring-station-accent/70">
				{/* 勾号用 SVG 而不是 '✓' 字形：文本字形的基线会让勾号视觉偏下，矢量路径能精确居中。 */}
				{checked && (
					<svg aria-hidden="true" viewBox="0 0 16 16" className="size-3 transition-transform duration-150 animate-in zoom-in-75">
						<path d="M4 8.4 6.7 11 12 5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
					</svg>
				)}
			</span>
		</label>
	);
}
