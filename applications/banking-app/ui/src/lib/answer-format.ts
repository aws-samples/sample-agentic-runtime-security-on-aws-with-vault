/**
 * answer-format.ts — the small part of Markdown a model answer uses, turned into plain data
 * that a component renders as text nodes: paragraphs, bulleted and numbered lists (nested by
 * indentation), and **bold**. Nothing here produces HTML, so nothing the model writes can
 * become an element: a "<b>" or "<img …>" in the answer stays the characters it is.
 *
 * On top of the model's own bold, every account number (OVI-XXX-NNNNNN) and every dollar
 * amount ($ then digits, with optional thousands separators and cents) is bold, as the
 * approved board draws the answer. Text the model already bolded is left as it is, so
 * nothing is bolded twice. A "**" with no partner is dropped rather than shown.
 */

export interface Piece {
	text: string;
	bold: boolean;
}

/** One line of text: the pieces it is made of, in order. */
export type Line = Piece[];

export interface Paragraph {
	kind: 'paragraph';
	/** Lines that were separated by single line breaks. */
	lines: Line[];
}

export interface ListItem {
	lines: Line[];
	/** Lists nested under this item. */
	lists: List[];
}

export interface List {
	kind: 'list';
	ordered: boolean;
	/** The number an ordered list starts at. */
	start: number;
	items: ListItem[];
}

export type Block = Paragraph | List;

const ITEM = /^(\s*)([-*•]|\d{1,9}[.)])\s+(.*)$/;
/** Deeper by this many columns makes an item a child of the one above it. */
const NEST = 2;
const HIGHLIGHT = /OVI-[A-Z]{3}-\d{6}(?!\d)|\$\d+(?:,\d{3})*(?:\.\d{2})?/g;

function columns(indent: string): number {
	return indent.replace(/\t/g, '    ').length;
}

/** Splits unbolded text so each account number and dollar amount is its own bold piece. */
function highlight(text: string): Piece[] {
	const pieces: Piece[] = [];
	let at = 0;
	for (const match of text.matchAll(HIGHLIGHT)) {
		const index = match.index ?? 0;
		if (index > at) pieces.push({ text: text.slice(at, index), bold: false });
		pieces.push({ text: match[0], bold: true });
		at = index + match[0].length;
	}
	if (at < text.length) pieces.push({ text: text.slice(at), bold: false });
	return pieces;
}

/** One line of the answer as pieces: the model's **bold**, then the highlighted values. */
export function formatLine(text: string): Line {
	const parts = text.split('**');
	const pieces: Piece[] = [];
	parts.forEach((part, i) => {
		// An odd part is bold when a closing "**" follows it; the last odd part of an even
		// count has no partner, and its opening "**" is simply dropped.
		const bold = i % 2 === 1 && (i < parts.length - 1 || parts.length % 2 === 1);
		if (part === '') return;
		if (bold) pieces.push({ text: part, bold: true });
		else pieces.push(...highlight(part));
	});
	// Neighbours of the same weight become one piece.
	return pieces.reduce<Piece[]>((out, piece) => {
		const last = out.at(-1);
		if (last && last.bold === piece.bold) last.text += piece.text;
		else out.push({ ...piece });
		return out;
	}, []);
}

/** The answer as blocks. See the module comment for what is recognised. */
export function formatAnswer(text: string): Block[] {
	const blocks: Block[] = [];
	let paragraph: Paragraph | null = null;
	/** The open lists, outermost first, each with the indentation of its items. */
	let open: { list: List; indent: number }[] = [];
	let blankBefore = false;

	const lastItem = () => open.at(-1)?.list.items.at(-1);

	for (const raw of text.replace(/\r\n?/g, '\n').split('\n')) {
		if (raw.trim() === '') {
			paragraph = null;
			blankBefore = true;
			continue;
		}
		const item = ITEM.exec(raw);
		if (item) {
			paragraph = null;
			const indent = columns(item[1]);
			const ordered = /\d/.test(item[2]);
			while (open.length > 0 && open[open.length - 1].indent > indent + (NEST - 1)) open.pop();
			let top = open.at(-1);
			if (top && indent < top.indent + NEST && top.list.ordered !== ordered) {
				open.pop();
				top = open.at(-1);
			}
			const entry: ListItem = { lines: [formatLine(item[3])], lists: [] };
			if (top && indent < top.indent + NEST) {
				top.list.items.push(entry);
			} else {
				const list: List = { kind: 'list', ordered, start: ordered ? parseInt(item[2], 10) : 1, items: [entry] };
				const parent = top?.list.items.at(-1);
				if (parent) parent.lists.push(list);
				else blocks.push(list);
				open.push({ list, indent });
			}
			blankBefore = false;
			continue;
		}
		// Text that is not a list item: more of the item above it when it follows directly or
		// is indented under it, otherwise a paragraph.
		const under = lastItem();
		if (under && (!blankBefore || columns(/^\s*/.exec(raw)?.[0] ?? '') >= NEST)) {
			under.lines.push(formatLine(raw.trim()));
		} else {
			open = [];
			if (paragraph && !blankBefore) paragraph.lines.push(formatLine(raw.trim()));
			else {
				paragraph = { kind: 'paragraph', lines: [formatLine(raw.trim())] };
				blocks.push(paragraph);
			}
		}
		blankBefore = false;
	}
	return blocks;
}
