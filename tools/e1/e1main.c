#include <stdio.h>
extern int e1_greet(const char*);
extern int e1_add(int,int);
int main(void){int s=e1_greet("x")+e1_add(20,22);printf("e1 dynamic main: greet+add=0\n",s);return s==49?0:1;}
