export type Node = {
  id: number;
  typeId: number;
  type: string;
  text: string;
  namedChildren: Node[];
};

export const children = (n: Node) => n.namedChildren;
