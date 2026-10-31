import { Icon } from '@/shared/components/Icon';

interface Props {
	value: string;
	onChange: (value: string) => void;
	placeholder: string;
	/** 外层容器宽度等额外类（如 w-52 / flex-1）。 */
	className?: string;
	autoFocus?: boolean;
	'aria-label'?: string;
}

/** 列表搜索框：搜索图标 + 受控输入，统一各页面重复的 label + icon + input 结构。 */
export function SearchInput({
	value,
	onChange,
	placeholder,
	className = '',
	autoFocus = false,
	'aria-label': ariaLabel,
}: Props): React.JSX.Element {
	return (
		<label className={`station-input ${className}`.trim()}>
			<Icon name="search" className="size-3.5" />
			<input
				value={value}
				onChange={(event) => onChange(event.target.value)}
				className="min-w-0 flex-1 bg-transparent text-xs text-station-text outline-none placeholder:text-station-subtle"
				placeholder={placeholder}
				autoFocus={autoFocus}
				aria-label={ariaLabel}
			/>
		</label>
	);
}
