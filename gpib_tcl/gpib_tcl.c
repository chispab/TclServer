#include <stdio.h>
#include <windows.h>
#include <tcl.h>
#include "decl-32.h"

static void found (HWND hwnd, unsigned int fluke);
static void gpiberr (HWND hwnd, char far *call);
static void record (HWND hwnd, int indx, char far *call);

#define  MAVbit   0x10           /* Position of the Message Available bit.  */

char          buffer[101];       /* Data received from the Fluke 45         */
int           loop,              /* FOR loop counter and array index        */
              m,                 /* FOR loop counter                        */
              num_listeners,     /* Number of listeners on GPIB             */
              pad;               /* Primary address of listener on GPIB     */
short         SRQasserted,       /* Set to indicate if SRQ is asserted      */
              statusByte;        /* Serial Poll Response Byte               */
double        sum;               /* Accumulator of measurements             */
Addr4882_t    fluke,             /* Primary address of the Fluke 45         */
              instruments[32],   /* Array of primary addresses              */
              result[31];        /* Array of listen addresses               */

char *ecodes[] = {
   "EDVR", "ECIC", "ENOL", "EADR", "EARG", "ESAC",
   "EABO", "ENEB", "EDMA", "EBTO", "EOIP", "ECAP", "EFSO",
   "none", "EBUS", "ESTB", "ESRQ"
   };

int lineindx;
char str[2048];

/*
 *  CODE TO ACCESS GPIB-32.DLL
 */

static void (__stdcall *PDevClear)(int boardID, Addr4882_t addr);
static void (__stdcall *PFindLstn)(int boardID, Addr4882_t * addrlist, PSHORT results, int limit);
static int  (__stdcall *Pibonl)(int ud, int v);
static void (__stdcall *PReadStatusByte)(int boardID, Addr4882_t addr, PSHORT result);
static void (__stdcall *PReceive)(int boardID, Addr4882_t addr, PVOID buffer, LONG cnt, int Termination);
static void (__stdcall *PSend)(int boardID, Addr4882_t addr, PVOID databuf, LONG datacnt, int eotMode);
static void (__stdcall *PSendIFC)(int boardID);
static void (__stdcall *PWaitSRQ)(int boardID, PSHORT result);
static void (__stdcall *PFindRQS)(int boardID, Addr4882_t *addrlist, PSHORT result);
static void (__stdcall *PTestSRQ)(int boardID, PSHORT result);
static int  (__stdcall *Pibtmo)(int ud, int v);


/*
 *    This is private data for the language interface only so it is
 *    defined as 'static'.
 */
static HINSTANCE Gpib32Lib = NULL;
static int *Pibsta;
static int *Piberr;
static long *Pibcntl;


int GPIB_sendIFC(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj* CONST objv[])
{
	int boardID=0;
	if (objc != 2) {
		Tcl_WrongNumArgs(interp, 1, objv, "boardID");
		return TCL_ERROR;
	}
	Tcl_GetIntFromObj(interp,objv[1],&boardID);

    (*PSendIFC)(boardID); // Set board to Controller-in-Charge
	return TCL_OK;
}

int GPIB_send(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj* CONST objv[])
{
	int boardID=0;
	int address=0;
	char* cmd;
	int count=0;
	int eotmode=0;
	if (objc != 5) {
		Tcl_WrongNumArgs(interp, 1, objv, "boardID address cmd eotmode");
		return TCL_ERROR;
	}
	Tcl_GetIntFromObj(interp,objv[1],&boardID);
	Tcl_GetIntFromObj(interp,objv[2],&address);
	cmd = Tcl_GetStringFromObj(objv[3],&count);
	Tcl_GetIntFromObj(interp,objv[4],&eotmode);

    (*PSend)(boardID,(short) address, cmd,(long) count,(short) eotmode);

	return TCL_OK;	
}


int GPIB_receive(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj* CONST objv[])
{
   	int boardID=0;
	int address=0;
	int count=0;
	int termination=0;
	char buffer[65536];
	if (objc != 5) {
		Tcl_WrongNumArgs(interp, 1, objv, "boardID address count termination");
		return TCL_ERROR;
	}
	Tcl_GetIntFromObj(interp,objv[1],&boardID);
	Tcl_GetIntFromObj(interp,objv[2],&address);
	Tcl_GetIntFromObj(interp,objv[3],&count);
	Tcl_GetIntFromObj(interp,objv[4],&termination);

	(*PReceive)(boardID,(short) address, buffer,(long) count, termination);

	Tcl_SetObjResult(interp,Tcl_NewStringObj(buffer,(*Pibcntl)));
	return TCL_OK;
}

int GPIB_devClear(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj* CONST objv[])
{
	int boardID=0;
	int address=0;
	if (objc != 3) {
		Tcl_WrongNumArgs(interp, 1, objv, "boardID address");
		return TCL_ERROR;
	}
	Tcl_GetIntFromObj(interp,objv[1],&boardID);
	Tcl_GetIntFromObj(interp,objv[2],&address);

	(*PDevClear) (boardID,(short) address); // Set board online (<> 0) / offline (0)

	return TCL_OK;	
}

int GPIB_findLstn(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj* CONST objv[])
{
	Tcl_Obj *listPtr;

	for (loop = 0; loop <= 30; loop++) {
		instruments[loop] = (Addr4882_t)loop;
	}
	instruments[31] = NOADDR;
	(*PFindLstn)(0, &instruments[1], (Addr4882_t *)result, 31);
	num_listeners = (short)(*Pibcntl);
	
	listPtr = Tcl_NewListObj(0,NULL);
	for (loop = 0; loop < num_listeners; loop++) {
		Tcl_ListObjAppendElement(interp, listPtr, Tcl_NewIntObj((int)result[loop]));
	}

	Tcl_SetObjResult(interp,listPtr);
	return TCL_OK;
}

int GPIB_readStatusByte(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj* CONST objv[])
{
	short result = 0;
	int boardID=0;
	int address=0;
	if (objc != 3) {
		Tcl_WrongNumArgs(interp, 1, objv, "boardID address");
		return TCL_ERROR;
	}
	Tcl_GetIntFromObj(interp,objv[1],&boardID);
	Tcl_GetIntFromObj(interp,objv[2],&address);

	(*PReadStatusByte)(boardID,(short) address, &result);

	Tcl_SetObjResult(interp,Tcl_NewIntObj((int)result));
	return TCL_OK;
}

int GPIB_readStatusVariables(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj* CONST objv[])
{
	Tcl_Obj *listPtr;
	listPtr = Tcl_NewListObj(0,NULL);
	Tcl_ListObjAppendElement(interp, listPtr, Tcl_NewIntObj((long) *Pibsta));
	Tcl_ListObjAppendElement(interp, listPtr, Tcl_NewIntObj((long) *Piberr));
	Tcl_ListObjAppendElement(interp, listPtr, Tcl_NewIntObj(*Pibcntl));
	Tcl_SetObjResult(interp,listPtr);
	return TCL_OK;
}

int GPIB_waitSRQ(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj* CONST objv[])
{
	short result = 0;
	int boardID=0;
	if (objc != 2) {
		Tcl_WrongNumArgs(interp, 1, objv, "boardID");
		return TCL_ERROR;
	}
	Tcl_GetIntFromObj(interp,objv[1],&boardID);

    (*PWaitSRQ)(boardID, &result);
	
	Tcl_SetObjResult(interp,Tcl_NewIntObj((int)result));
	return TCL_OK;
}

int GPIB_ibtmo(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj* CONST objv[])
{
	short result = 0;
	int boardID=0;
	int value=0;
	if (objc != 3) {
		Tcl_WrongNumArgs(interp, 1, objv, "boardID value");
		return TCL_ERROR;
	}
	Tcl_GetIntFromObj(interp,objv[1],&boardID);
	Tcl_GetIntFromObj(interp,objv[2],&value);

	result = (*Pibtmo)(boardID, value);

	Tcl_SetObjResult(interp,Tcl_NewIntObj((int)result));
	return TCL_OK;

    
}

int GPIB_sendBinary(ClientData clientData, Tcl_Interp *interp, int objc, Tcl_Obj* CONST objv[])
{
	int boardID=0;
	int address=0;
	char* buf;
	char* filename=NULL;
	int count=0;
	int eotmode=0;
	FILE* f;
	if (objc != 5) {
		Tcl_WrongNumArgs(interp, 1, objv, "boardID address filename eotmode");
		return TCL_ERROR;
	}
	Tcl_GetIntFromObj(interp,objv[1],&boardID);
	Tcl_GetIntFromObj(interp,objv[2],&address);
	filename = Tcl_GetStringFromObj(objv[3],&count);
	Tcl_GetIntFromObj(interp,objv[4],&eotmode);

	// read binary data from file
	if ((f=fopen(filename,"rb")) == NULL) {
		Tcl_AddObjErrorInfo(interp,"Could not open file",19);
		Tcl_SetObjErrorCode(interp,Tcl_NewIntObj(-1));
		Tcl_AppendResult(interp, "Could not open file", (char*) NULL);
		return TCL_ERROR;
	}
	buf = malloc(1024*1024);
	count=fread(buf,1,1024*1024,f);
	fclose(f);

    (*PSend)(boardID,(short) address, buf,(long) count,(short) eotmode);
	free(buf);

	return TCL_OK;
}

__declspec(dllexport) int Gpib_tcl_Init(Tcl_Interp *interp) 
{

	if (Tcl_InitStubs(interp, "8.1",0) == NULL) {
		return TCL_ERROR;
	}
	
	Gpib32Lib = LoadLibrary ("GPIB-32.DLL");
	if (!Gpib32Lib)  {
		fprintf(stderr,"GPIB-32.DLL could not be loaded\n");
		return TCL_ERROR;
	}

	// Retrieve pointers to the requested functions.
	Pibsta          = (int *) GetProcAddress(Gpib32Lib, (LPCSTR)"user_ibsta");
	Piberr          = (int *) GetProcAddress(Gpib32Lib, (LPCSTR)"user_iberr");
	Pibcntl         = (long *)GetProcAddress(Gpib32Lib, (LPCSTR)"user_ibcnt");

	PDevClear       = (void (__stdcall *)(int, Addr4882_t))GetProcAddress(Gpib32Lib, (LPCSTR)"DevClear");
	PFindLstn       = (void (__stdcall *)(int, Addr4882_t *, PSHORT, int))GetProcAddress(Gpib32Lib, (LPCSTR)"FindLstn");
	Pibonl          = (int  (__stdcall *)(int, int))GetProcAddress(Gpib32Lib, (LPCSTR)"ibonl");
	PReadStatusByte = (void (__stdcall *)(int, Addr4882_t, PSHORT))GetProcAddress(Gpib32Lib, (LPCSTR)"ReadStatusByte");
	PReceive        = (void (__stdcall *)(int, Addr4882_t, PVOID, LONG, int))GetProcAddress(Gpib32Lib, (LPCSTR)"Receive");
	PSend           = (void (__stdcall *)(int, Addr4882_t, PVOID, LONG, int))GetProcAddress(Gpib32Lib, (LPCSTR)"Send");
	PSendIFC        = (void (__stdcall *)(int))GetProcAddress(Gpib32Lib, (LPCSTR)"SendIFC");
	PWaitSRQ        = (void (__stdcall *)(int, PSHORT))GetProcAddress(Gpib32Lib, (LPCSTR)"WaitSRQ");
	PFindRQS        = (void (__stdcall *)(int, Addr4882_t *, PSHORT))GetProcAddress(Gpib32Lib, (LPCSTR)"FindRQS");
	PTestSRQ        = (void (__stdcall *)(int, PSHORT))GetProcAddress(Gpib32Lib, (LPCSTR)"TestSRQ");
	Pibtmo          = (int  (__stdcall *)(int, int))GetProcAddress(Gpib32Lib, (LPCSTR)"ibtmo");

	if ((Pibsta         == NULL) ||
		(Piberr         == NULL) ||
		(Pibcntl        == NULL) ||
		(PDevClear      == NULL) ||
		(PFindLstn      == NULL) ||
		(Pibonl         == NULL) ||
		(PReadStatusByte== NULL) ||
		(PReceive       == NULL) ||
		(PSend          == NULL) ||
		(PSendIFC       == NULL) ||
		(PWaitSRQ       == NULL))  {

		FreeLibrary (Gpib32Lib);
		Gpib32Lib = NULL;
		return TCL_ERROR;
	}

	Tcl_CreateObjCommand(interp, "GPIB_sendIFC", GPIB_sendIFC, (ClientData)NULL, (Tcl_CmdDeleteProc *)NULL);
	Tcl_CreateObjCommand(interp, "GPIB_send", GPIB_send, (ClientData)NULL, (Tcl_CmdDeleteProc *)NULL);
	Tcl_CreateObjCommand(interp, "GPIB_receive", GPIB_receive, (ClientData)NULL, (Tcl_CmdDeleteProc *)NULL);
	Tcl_CreateObjCommand(interp, "GPIB_devClear", GPIB_devClear, (ClientData)NULL, (Tcl_CmdDeleteProc *)NULL);
	Tcl_CreateObjCommand(interp, "GPIB_findLstn", GPIB_findLstn, (ClientData)NULL, (Tcl_CmdDeleteProc *)NULL);
	Tcl_CreateObjCommand(interp, "GPIB_readStatusByte", GPIB_readStatusByte, (ClientData)NULL, (Tcl_CmdDeleteProc *)NULL);
	Tcl_CreateObjCommand(interp, "GPIB_readStatusVariables", GPIB_readStatusVariables, (ClientData)NULL, (Tcl_CmdDeleteProc *)NULL);
	Tcl_CreateObjCommand(interp, "GPIB_waitSRQ", GPIB_waitSRQ, (ClientData)NULL, (Tcl_CmdDeleteProc *)NULL);
	Tcl_CreateObjCommand(interp, "GPIB_ibtmo", GPIB_ibtmo, (ClientData)NULL, (Tcl_CmdDeleteProc *)NULL);
	Tcl_CreateObjCommand(interp, "GPIB_sendBinary", GPIB_sendBinary, (ClientData)NULL, (Tcl_CmdDeleteProc *)NULL);

	Tcl_PkgProvide(interp, "gpib_tcl", "1.0");
	return TCL_OK;
}


/*************************************************************************
* Following functions are not ported, because they are not used from TCL
**************************************************************************

//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

JNIEXPORT void JNICALL Java_JTT_IOFunctions_GPIBJNI_ibonl
  (JNIEnv *env, jobject obj, jint boardID, jint online)
{
	if (debug)
		printf("ibonl\n");
    (*Pibonl) (boardID,online); // Set board online (<> 0) / offline (0)
	return;	
}

//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

JNIEXPORT jint JNICALL Java_JTT_IOFunctions_GPIBJNI_findRQS
  (JNIEnv *env, jobject obj, jint boardID, jintArray addressList)
{
	if (debug)
		printf("findRQS\n");
	jint *addrsList = env->GetIntArrayElements(addressList, 0);
	jsize len = env->GetArrayLength(addressList);
	short instrum[32];
    for (int i = 1; i <= len; i++) {
		instrum[i-1] = (short) addrsList[i-1];
    }
    instrum[len] = NOADDR; // Constant NOADDR, defined in DECL-32.H, signifies the end of the array.
    short result = 0;
    (*PFindRQS)(boardID, &instrum[0], &result);
	env->ReleaseIntArrayElements(addressList, addrsList, 0);
	return (jint) result;
}

//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

JNIEXPORT jint JNICALL Java_JTT_IOFunctions_GPIBJNI_testSRQ
  (JNIEnv *env, jobject obj, jint boardID)
{
	if (debug)
		printf("testSRQ\n");
    short result = 0;
    (*PTestSRQ)(boardID, &result);
	return result;
}

//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
*/