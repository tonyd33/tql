export type Node = {
  id: number;
  typeId: number;
  type: string;
  text: string;
  children: Node[];
};

export const children = (n: Node) => n.children;
