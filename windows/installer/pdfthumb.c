// File Explorer thumbnails of PDF files: the first page, drawn by the PDF renderer of Windows
// (Windows.Data.Pdf, Windows 8.1 and later). The installer registers it (installer.nsh).
// Build: ./build-thumbnail.sh (MinGW-w64) makes pdfthumb.dll next to this file.
//
// File Explorer runs it in a separate process (dllhost.exe) and passes the file as an IStream.
// The file is read into memory first, so the renderer's own threads never touch File Explorer's
// stream. MinGW has no header for Windows.Data.Pdf, so its interfaces are written out here
// (IIDs and method order from the Windows metadata); the DLL needs nothing but Windows itself.

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <roapi.h>
#include <shcore.h>
#include <shlwapi.h>
#include <thumbcache.h>
#include <wincodec.h>
#include <winstring.h>

// MARK: - WinRT, written out by hand

typedef enum { AsyncStarted = 0, AsyncCompleted = 1, AsyncCanceled = 2, AsyncError = 3 } AsyncStatus_;

/// Every WinRT interface starts with IUnknown and IInspectable; `IInspectableSlots` fills those slots.
#define IInspectableSlots(T)                                    \
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(T *, REFIID, void **); \
    ULONG (STDMETHODCALLTYPE *AddRef)(T *);                     \
    ULONG (STDMETHODCALLTYPE *Release)(T *);                    \
    void *GetIids, *GetRuntimeClassName, *GetTrustLevel;

typedef struct IAsyncInfo_ { const struct IAsyncInfoVtbl_ *v; } IAsyncInfo_;
struct IAsyncInfoVtbl_ {
    IInspectableSlots(IAsyncInfo_)
    void *get_Id;
    HRESULT (STDMETHODCALLTYPE *get_Status)(IAsyncInfo_ *, AsyncStatus_ *);
    HRESULT (STDMETHODCALLTYPE *get_ErrorCode)(IAsyncInfo_ *, HRESULT *);
    HRESULT (STDMETHODCALLTYPE *Cancel)(IAsyncInfo_ *);
};

/// IAsyncAction and IAsyncOperation<T> share this layout; GetResults takes no argument for an action.
typedef struct IAsync_ { const struct IAsyncVtbl_ *v; } IAsync_;
struct IAsyncVtbl_ {
    IInspectableSlots(IAsync_)
    void *put_Completed, *get_Completed;
    HRESULT (STDMETHODCALLTYPE *GetResults)(IAsync_ *, void *result);
};

typedef struct IPdfPageRenderOptions_ { const struct IPdfPageRenderOptionsVtbl_ *v; } IPdfPageRenderOptions_;
struct IPdfPageRenderOptionsVtbl_ {
    IInspectableSlots(IPdfPageRenderOptions_)
    void *get_SourceRect, *put_SourceRect;
    void *get_DestinationWidth;
    HRESULT (STDMETHODCALLTYPE *put_DestinationWidth)(IPdfPageRenderOptions_ *, UINT32);
    void *get_DestinationHeight;
    HRESULT (STDMETHODCALLTYPE *put_DestinationHeight)(IPdfPageRenderOptions_ *, UINT32);
};

typedef struct { FLOAT Width, Height; } Size_;

typedef struct IPdfPage_ { const struct IPdfPageVtbl_ *v; } IPdfPage_;
struct IPdfPageVtbl_ {
    IInspectableSlots(IPdfPage_)
    void *RenderToStreamAsync;
    HRESULT (STDMETHODCALLTYPE *RenderWithOptionsToStreamAsync)(IPdfPage_ *, IUnknown *stream,
                                                                IPdfPageRenderOptions_ *, IAsync_ **);
    void *PreparePageAsync, *get_Index;
    HRESULT (STDMETHODCALLTYPE *get_Size)(IPdfPage_ *, Size_ *);
};

typedef struct IPdfDocument_ { const struct IPdfDocumentVtbl_ *v; } IPdfDocument_;
struct IPdfDocumentVtbl_ {
    IInspectableSlots(IPdfDocument_)
    HRESULT (STDMETHODCALLTYPE *GetPage)(IPdfDocument_ *, UINT32, IPdfPage_ **);
    HRESULT (STDMETHODCALLTYPE *get_PageCount)(IPdfDocument_ *, UINT32 *);
};

typedef struct IPdfDocumentStatics_ { const struct IPdfDocumentStaticsVtbl_ *v; } IPdfDocumentStatics_;
struct IPdfDocumentStaticsVtbl_ {
    IInspectableSlots(IPdfDocumentStatics_)
    void *LoadFromFileAsync, *LoadFromFileWithPasswordAsync;
    HRESULT (STDMETHODCALLTYPE *LoadFromStreamAsync)(IPdfDocumentStatics_ *, IUnknown *stream, IAsync_ **);
};

static const GUID IID_IAsyncInfo_ = {0x00000036, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID IID_IRandomAccessStream_ = {0x905A0FE1, 0xBC53, 0x11DF, {0x8C, 0x49, 0x00, 0x1E, 0x4F, 0xC6, 0x86, 0xDA}};
static const GUID IID_IPdfDocumentStatics_ = {0x433A0B5F, 0xC007, 0x4788, {0x90, 0xF2, 0x08, 0x14, 0x3D, 0x92, 0x25, 0x99}};
// Not in MinGW's libuuid.
static const GUID IID_IThumbnailProvider_ = {0xE357FCCD, 0xA995, 0x4576, {0xB0, 0x1F, 0x23, 0x46, 0x30, 0x15, 0x4E, 0x96}};
static const GUID IID_IPdfPageRenderOptions_ = {0x3C98056F, 0xB7CF, 0x4C29, {0x9A, 0x04, 0x52, 0xD9, 0x02, 0x67, 0xF4, 0x25}};

/// Waits for a WinRT async call; File Explorer gives up on a thumbnail after a while, and so do we.
static HRESULT waitFor(IAsync_ *op) {
    IAsyncInfo_ *info = NULL;
    HRESULT hr = op->v->QueryInterface(op, &IID_IAsyncInfo_, (void **)&info);
    if (FAILED(hr)) return hr;
    AsyncStatus_ status = AsyncStarted;
    for (DWORD start = GetTickCount(); status == AsyncStarted;) {
        if (FAILED(hr = info->v->get_Status(info, &status))) break;
        if (status != AsyncStarted) break;
        if (GetTickCount() - start > 20000) {
            info->v->Cancel(info);
            hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
            break;
        }
        Sleep(2);
    }
    if (SUCCEEDED(hr) && status != AsyncCompleted) {
        if (status != AsyncError || FAILED(info->v->get_ErrorCode(info, &hr)) || SUCCEEDED(hr)) hr = E_FAIL;
    }
    info->v->Release(info); // not Close: that would end GetResults too
    return hr;
}

static IUnknown *randomAccessStream(IStream *stream) {
    IUnknown *ras = NULL;
    return SUCCEEDED(CreateRandomAccessStreamOverStream(stream, BSOS_DEFAULT, &IID_IRandomAccessStream_, (void **)&ras))
               ? ras : NULL;
}

// MARK: - Rendering

/// The whole file, in a stream of our own. Larger files get no thumbnail.
static IStream *readAll(IStream *source) {
    STATSTG stat;
    if (FAILED(IStream_Stat(source, &stat, STATFLAG_NONAME)) || stat.cbSize.QuadPart == 0 ||
        stat.cbSize.QuadPart > 512u * 1024 * 1024)
        return NULL;
    ULONG size = (ULONG)stat.cbSize.QuadPart;
    BYTE *bytes = HeapAlloc(GetProcessHeap(), 0, size);
    if (!bytes) return NULL;
    LARGE_INTEGER zero = {0};
    IStream *copy = NULL;
    ULONG done = 0, got = 0;
    if (SUCCEEDED(IStream_Seek(source, zero, STREAM_SEEK_SET, NULL))) {
        while (done < size && SUCCEEDED(IStream_Read(source, bytes + done, size - done, &got)) && got > 0)
            done += got;
        if (done == size) copy = SHCreateMemStream(bytes, size);
    }
    HeapFree(GetProcessHeap(), 0, bytes);
    return copy;
}

/// Renders the first page as a PNG into `png`, `side` pixels on its longer side.
static HRESULT renderFirstPage(IStream *pdf, UINT side, IStream *png) {
    HSTRING_HEADER h1, h2;
    HSTRING documentClass, optionsClass;
    static const WCHAR documentName[] = L"Windows.Data.Pdf.PdfDocument";
    static const WCHAR optionsName[] = L"Windows.Data.Pdf.PdfPageRenderOptions";
    WindowsCreateStringReference(documentName, ARRAYSIZE(documentName) - 1, &h1, &documentClass);
    WindowsCreateStringReference(optionsName, ARRAYSIZE(optionsName) - 1, &h2, &optionsClass);

    IPdfDocumentStatics_ *statics = NULL;
    IUnknown *input = NULL, *output = NULL;
    IAsync_ *load = NULL, *render = NULL;
    IPdfDocument_ *document = NULL;
    IPdfPage_ *page = NULL;
    IInspectable *optionsObject = NULL;
    IPdfPageRenderOptions_ *options = NULL;
    UINT32 count = 0;
    Size_ size;

    HRESULT hr = RoGetActivationFactory(documentClass, &IID_IPdfDocumentStatics_, (void **)&statics);
    if (SUCCEEDED(hr)) hr = (input = randomAccessStream(pdf)) ? S_OK : E_FAIL;
    if (SUCCEEDED(hr)) hr = statics->v->LoadFromStreamAsync(statics, input, &load);
    if (SUCCEEDED(hr)) hr = waitFor(load);
    if (SUCCEEDED(hr)) hr = load->v->GetResults(load, &document);
    if (SUCCEEDED(hr)) hr = document->v->get_PageCount(document, &count);
    if (SUCCEEDED(hr) && count == 0) hr = E_FAIL;
    if (SUCCEEDED(hr)) hr = document->v->GetPage(document, 0, &page);
    if (SUCCEEDED(hr)) hr = page->v->get_Size(page, &size);
    if (SUCCEEDED(hr) && (size.Width < 1 || size.Height < 1)) hr = E_FAIL;
    if (SUCCEEDED(hr)) hr = RoActivateInstance(optionsClass, &optionsObject);
    if (SUCCEEDED(hr)) hr = IInspectable_QueryInterface(optionsObject, &IID_IPdfPageRenderOptions_, (void **)&options);
    if (SUCCEEDED(hr)) {
        // Both sides are set, so the page keeps its shape; at least one pixel each way.
        double scale = side / (size.Width > size.Height ? size.Width : size.Height);
        UINT32 width = (UINT32)(size.Width * scale + 0.5), height = (UINT32)(size.Height * scale + 0.5);
        options->v->put_DestinationWidth(options, width ? width : 1);
        options->v->put_DestinationHeight(options, height ? height : 1);
        hr = (output = randomAccessStream(png)) ? S_OK : E_FAIL;
    }
    if (SUCCEEDED(hr)) hr = page->v->RenderWithOptionsToStreamAsync(page, output, options, &render);
    if (SUCCEEDED(hr)) hr = waitFor(render);
    if (SUCCEEDED(hr)) hr = render->v->GetResults(render, NULL);

    if (render) render->v->Release(render);
    if (options) options->v->Release(options);
    if (optionsObject) IInspectable_Release(optionsObject);
    if (page) page->v->Release(page);
    if (document) document->v->Release(document);
    if (load) load->v->Release(load);
    if (output) IUnknown_Release(output);
    if (input) IUnknown_Release(input);
    if (statics) statics->v->Release(statics);
    return hr;
}

/// Decodes the PNG into a top-down 32-bit bitmap, the form File Explorer wants.
static HRESULT bitmapFromPNG(IStream *png, HBITMAP *bitmap) {
    IWICImagingFactory *factory = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapFrameDecode *frame = NULL;
    IWICBitmapSource *converted = NULL;
    UINT width = 0, height = 0;
    LARGE_INTEGER zero = {0};

    HRESULT hr = IStream_Seek(png, zero, STREAM_SEEK_SET, NULL);
    if (SUCCEEDED(hr))
        hr = CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory,
                              (void **)&factory);
    if (SUCCEEDED(hr))
        hr = IWICImagingFactory_CreateDecoderFromStream(factory, png, NULL, WICDecodeMetadataCacheOnDemand, &decoder);
    if (SUCCEEDED(hr)) hr = IWICBitmapDecoder_GetFrame(decoder, 0, &frame);
    if (SUCCEEDED(hr))
        hr = WICConvertBitmapSource(&GUID_WICPixelFormat32bppBGRA, (IWICBitmapSource *)frame, &converted);
    if (SUCCEEDED(hr)) hr = IWICBitmapSource_GetSize(converted, &width, &height);
    if (SUCCEEDED(hr)) {
        BITMAPINFO info = {.bmiHeader = {.biSize = sizeof(BITMAPINFOHEADER), .biWidth = (LONG)width,
                                         .biHeight = -(LONG)height, .biPlanes = 1, .biBitCount = 32,
                                         .biCompression = BI_RGB}};
        void *pixels = NULL;
        HBITMAP made = CreateDIBSection(NULL, &info, DIB_RGB_COLORS, &pixels, NULL, 0);
        hr = made ? IWICBitmapSource_CopyPixels(converted, NULL, width * 4, width * height * 4, pixels) : E_OUTOFMEMORY;
        if (SUCCEEDED(hr)) *bitmap = made;
        else if (made) DeleteObject(made);
    }
    if (converted) IWICBitmapSource_Release(converted);
    if (frame) IWICBitmapFrameDecode_Release(frame);
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (factory) IWICImagingFactory_Release(factory);
    return hr;
}

// MARK: - The thumbnail provider

static LONG objects;

// {3C524D7A-F39E-4C72-A665-B12AE525F3C0}, the CLSID in installer.nsh
static const GUID CLSID_PDFThumbnails = {0x3C524D7A, 0xF39E, 0x4C72, {0xA6, 0x65, 0xB1, 0x2A, 0xE5, 0x25, 0xF3, 0xC0}};

typedef struct {
    IThumbnailProvider provider;
    IInitializeWithStream init;
    LONG refs;
    IStream *stream;
} Thumbnails;

#define FROM_PROVIDER(p) ((Thumbnails *)(p))
#define FROM_INIT(p) ((Thumbnails *)((BYTE *)(p) - offsetof(Thumbnails, init)))

static HRESULT STDMETHODCALLTYPE query(Thumbnails *t, REFIID riid, void **out) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IThumbnailProvider_)) *out = &t->provider;
    else if (IsEqualIID(riid, &IID_IInitializeWithStream)) *out = &t->init;
    else { *out = NULL; return E_NOINTERFACE; }
    InterlockedIncrement(&t->refs);
    return S_OK;
}

static ULONG STDMETHODCALLTYPE release(Thumbnails *t) {
    LONG refs = InterlockedDecrement(&t->refs);
    if (refs == 0) {
        if (t->stream) IStream_Release(t->stream);
        HeapFree(GetProcessHeap(), 0, t);
        InterlockedDecrement(&objects);
    }
    return refs;
}

static HRESULT STDMETHODCALLTYPE providerQuery(IThumbnailProvider *p, REFIID riid, void **out) { return query(FROM_PROVIDER(p), riid, out); }
static ULONG STDMETHODCALLTYPE providerAddRef(IThumbnailProvider *p) { return InterlockedIncrement(&FROM_PROVIDER(p)->refs); }
static ULONG STDMETHODCALLTYPE providerRelease(IThumbnailProvider *p) { return release(FROM_PROVIDER(p)); }

static HRESULT STDMETHODCALLTYPE getThumbnail(IThumbnailProvider *p, UINT cx, HBITMAP *bitmap, WTS_ALPHATYPE *alpha) {
    Thumbnails *t = FROM_PROVIDER(p);
    if (!bitmap || !alpha) return E_POINTER;
    *bitmap = NULL;
    if (!t->stream) return E_FAIL;
    IStream *pdf = readAll(t->stream);
    if (!pdf) return E_FAIL;
    IStream *png = SHCreateMemStream(NULL, 0);
    HRESULT hr = png ? renderFirstPage(pdf, cx ? cx : 256, png) : E_OUTOFMEMORY;
    if (SUCCEEDED(hr)) hr = bitmapFromPNG(png, bitmap);
    if (SUCCEEDED(hr)) *alpha = WTSAT_RGB; // the page is drawn on white
    if (png) IStream_Release(png);
    IStream_Release(pdf);
    return hr;
}

static HRESULT STDMETHODCALLTYPE initQuery(IInitializeWithStream *p, REFIID riid, void **out) { return query(FROM_INIT(p), riid, out); }
static ULONG STDMETHODCALLTYPE initAddRef(IInitializeWithStream *p) { return InterlockedIncrement(&FROM_INIT(p)->refs); }
static ULONG STDMETHODCALLTYPE initRelease(IInitializeWithStream *p) { return release(FROM_INIT(p)); }

static HRESULT STDMETHODCALLTYPE initialize(IInitializeWithStream *p, IStream *stream, DWORD mode) {
    (void)mode;
    Thumbnails *t = FROM_INIT(p);
    if (t->stream) return HRESULT_FROM_WIN32(ERROR_ALREADY_INITIALIZED);
    if (!stream) return E_POINTER;
    t->stream = stream;
    IStream_AddRef(stream);
    return S_OK;
}

static IThumbnailProviderVtbl providerVtbl = {providerQuery, providerAddRef, providerRelease, getThumbnail};
static IInitializeWithStreamVtbl initVtbl = {initQuery, initAddRef, initRelease, initialize};

// MARK: - Class factory and DLL exports

static HRESULT STDMETHODCALLTYPE factoryQuery(IClassFactory *f, REFIID riid, void **out) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IClassFactory)) { *out = f; return S_OK; }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE factoryAddRef(IClassFactory *f) { (void)f; return 2; } // static object
static ULONG STDMETHODCALLTYPE factoryRelease(IClassFactory *f) { (void)f; return 1; }

static HRESULT STDMETHODCALLTYPE createInstance(IClassFactory *f, IUnknown *outer, REFIID riid, void **out) {
    (void)f;
    *out = NULL;
    if (outer) return CLASS_E_NOAGGREGATION;
    Thumbnails *t = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof *t);
    if (!t) return E_OUTOFMEMORY;
    t->provider.lpVtbl = &providerVtbl;
    t->init.lpVtbl = &initVtbl;
    t->refs = 1;
    InterlockedIncrement(&objects);
    HRESULT hr = query(t, riid, out);
    release(t);
    return hr;
}

static HRESULT STDMETHODCALLTYPE lockServer(IClassFactory *f, BOOL lock) {
    (void)f;
    if (lock) InterlockedIncrement(&objects);
    else InterlockedDecrement(&objects);
    return S_OK;
}

static IClassFactoryVtbl factoryVtbl = {factoryQuery, factoryAddRef, factoryRelease, createInstance, lockServer};
static IClassFactory factory = {&factoryVtbl};

HRESULT WINAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void **out) {
    if (!IsEqualCLSID(clsid, &CLSID_PDFThumbnails)) { *out = NULL; return CLASS_E_CLASSNOTAVAILABLE; }
    return factoryQuery(&factory, riid, out);
}

HRESULT WINAPI DllCanUnloadNow(void) { return objects == 0 ? S_OK : S_FALSE; }

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
    return TRUE;
}
