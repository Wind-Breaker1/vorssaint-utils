/** 双链弹层通过 Portal 挂到 body，使用光标的视口坐标定位，避开祖先模糊边界与裁剪。 */

/** 弹层与光标行之间的间隙（与页面 8px 基准网格一致）。 */
export const LINK_PICKER_GAP = 8;
/** 弹层与容器边缘之间预留的余量。 */
export const LINK_PICKER_MARGIN = 8;
/** 列表区域的最大高度（与样式里 300px 的视觉上限一致）。 */
export const LINK_PICKER_LIST_MAX = 300;
/** 外层 p-2 的上下内边距（8px × 2）加上下边框（1px × 2），用于把列表高度换算成弹层高度。 */
export const LINK_PICKER_CHROME = 18;

/** 弹层锚点：位置相对视口，`space*` 是光标上下两侧还能放多高（不含间隙）。 */
export type LinkPickerAnchor = {
	/** 弹层左边缘（仅在视口边缘夹紧）。 */
	left: number;
	/** 显示在光标下方时，弹层顶边的偏移。 */
	below: number;
	/** 显示在光标上方时，弹层底边的偏移。 */
	above: number;
	/** 光标下方可用高度。 */
	spaceBelow: number;
	/** 光标上方可用高度。 */
	spaceAbove: number;
};

export type LinkPickerLayout = {
	placement: 'above' | 'below';
	/** 弹层顶边相对视口的偏移。 */
	top: number;
	/** 列表区域应使用的最大高度（≤ LINK_PICKER_LIST_MAX）。 */
	listMaxHeight: number;
};

/**
 * @param anchor 光标锚点
 * @param popupHeight 弹层自然高度（列表内容高度 + LINK_PICKER_CHROME），不含下面的压缩
 */
export function layoutLinkPicker(anchor: LinkPickerAnchor, popupHeight: number): LinkPickerLayout {
	const fitsBelow = anchor.spaceBelow >= popupHeight + LINK_PICKER_MARGIN;
	const fitsAbove = anchor.spaceAbove >= popupHeight + LINK_PICKER_MARGIN;
	// 默认在下方；下方放不下时，只要上方更宽敞就翻上去（上方也放不下时同样优先宽敞的一侧）。
	const placement: LinkPickerLayout['placement'] = !fitsBelow && (fitsAbove || anchor.spaceAbove > anchor.spaceBelow) ? 'above' : 'below';
	const space = placement === 'above' ? anchor.spaceAbove : anchor.spaceBelow;
	const listMaxHeight = Math.max(0, Math.min(LINK_PICKER_LIST_MAX, space - LINK_PICKER_MARGIN - LINK_PICKER_CHROME));
	const height = Math.min(popupHeight, listMaxHeight + LINK_PICKER_CHROME);
	return {
		placement,
		top: placement === 'above' ? Math.max(LINK_PICKER_MARGIN, anchor.above - height) : anchor.below,
		listMaxHeight,
	};
}
