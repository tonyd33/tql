@Controller()
class Class1 {
  meth1(): Type1 {}
}

@Controller()
class Class2 {
  meth1() {}
}

@Controller()
class Class3 {
  meth1(): Type1 {}
  meth2() {}
}

@Controller()
class Class4 {
  meth1(): Type1 {}
  meth2(): Type2 {}
  meth3() {}
}

@Controller()
class Class5 {
  meth1(): Type1 {}
  meth2() {}
  meth3() {}
}

@NotController()
class Class6 {
  meth1(): Type1 {}
}

@NotController()
class Class7 {
  meth1() {}
}

@Foo()
class SpecificClassName {
  meth1(): Type1 {}
  meth2() {}
}
