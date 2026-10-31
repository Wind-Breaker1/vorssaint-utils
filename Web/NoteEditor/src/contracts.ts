export type NoteType = "markdown" | "excalidraw";
export type NotePropertyType = "text" | "number" | "checkbox" | "date" | "list";
export type NotePropertyValue = string | number | boolean | string[];
export type NoteProperty = {
  id?: string;
  key: string;
  type: NotePropertyType;
  value: NotePropertyValue;
};
export type NoteDetail = {
  id: string;
  title: string;
  content: string;
  tags: string[];
  properties: NoteProperty[];
  type: NoteType;
};
export type NoteCard = { id: string; title: string };
