import { createElement, type ComponentPropsWithRef } from 'react';

type ScrollTag = 'div' | 'main' | 'section' | 'ul' | 'ol';
type Props<T extends ScrollTag> = {
	as?: T;
	/** 默认借回面板的右侧 8px；独立浮层或页面根节点使用 false。 */
	bleed?: boolean;
	/** 列表 4px、模块堆叠 8px；自定义网格或原始内容使用 none。 */
	layout?: 'list' | 'stack' | 'none';
	/** 允许内容在纵向滚动之外横向滚动，例如宽表格和 Markdown 预览。 */
	horizontal?: boolean;
	/** 独立浮层已有完整内边距时，不额外预留面板滚动条边距。 */
	gutter?: boolean;
} & ComponentPropsWithRef<T>;

/** 统一滚动方向、滚动条留白与布局；不读取父元素、不包装 ref。 */
export function ScrollContainer<T extends ScrollTag = 'div'>({
	as,
	bleed = true,
	layout = 'list',
	horizontal = false,
	gutter = true,
	className = '',
	children,
	...rest
}: Props<T>): React.JSX.Element {
	const spacing = layout === 'none' ? '' : `flex flex-col ${layout === 'stack' ? 'gap-2' : 'gap-1'}`;
	return createElement(
		as ?? 'div',
		{
			...rest,
			className: `min-h-0 min-w-0 overflow-y-auto ${horizontal ? 'overflow-x-auto' : ''} overscroll-contain ${gutter ? 'pr-2' : ''} ${gutter && bleed ? '-mr-2' : ''} ${layout === 'none' ? '' : 'flex-1'} ${spacing} ${className}`,
		},
		children,
	);
}
