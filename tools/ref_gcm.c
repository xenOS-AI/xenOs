#include <openssl/evp.h>
#include <stdio.h>
#include <string.h>
// gcc ref_gcm.c -o ref_gcm -lcrypto
// args: key(32hex) nonce(24hex) aad(hex) pt(hex)
static int hexval(char c){ return (c<='9')?c-'0':(c|0x20)-'a'+10; }
static void unhex(unsigned char* out, const char* in){ int n=strlen(in)/2; for(int i=0;i<n;i++) out[i]=(hexval(in[2*i])<<4)|hexval(in[2*i+1]); }
int main(int argc, char** argv){
    unsigned char key[64],nonce[64],aad[64],pt[256],ct[256],tag[16];
    int nkey=strlen(argv[1])/2, nn=strlen(argv[2])/2, na=strlen(argv[3])/2, np=strlen(argv[4])/2;
    unhex(key,argv[1]); unhex(nonce,argv[2]); unhex(aad,argv[3]); unhex(pt,argv[4]);
    EVP_CIPHER_CTX* c=EVP_CIPHER_CTX_new();
    EVP_EncryptInit_ex(c,EVP_aes_128_gcm(),NULL,NULL,NULL);
    EVP_EncryptInit_ex(c,NULL,NULL,key,nonce);
    int l=0,tl=0;
    if(na>0) EVP_EncryptUpdate(c,NULL,&l,aad,na);
    EVP_EncryptUpdate(c,ct,&l,pt,np);
    EVP_EncryptFinal_ex(c,ct+l,&tl);
    EVP_CIPHER_CTX_ctrl(c,EVP_CTRL_GCM_GET_TAG,16,tag);
    EVP_CIPHER_CTX_free(c);
    printf("CT="); for(int i=0;i<np;i++) printf("%02x",ct[i]); printf("\n");
    printf("TAG="); for(int i=0;i<16;i++) printf("%02x",tag[i]); printf("\n");
    return 0;
}