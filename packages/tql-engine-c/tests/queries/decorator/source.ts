@Controller()
class Service1 {
  meth1(): Type1 {}
}

@Controller()
class Service2 {
  meth1() {}
}

@Controller()
class Service3 {
  meth1(): Type1 {}
  meth2() {}
}

@Controller()
class Service4 {
  meth1(): Type1 {}
  meth2(): Type2 {}
  meth3() {}
}

@Controller()
class Service5 {
  meth1(): Type1 {}
  meth2() {}
  meth3() {}
}

@NotController()
class Service6 {
  meth1(): Type1 {}
}

@NotController()
class Service7 {
  meth1() {}
}

