import winlean,asyncdispatch
type
  CustomOverlapped = object of OVERLAPPED
    data*: CompletionData

  PCustomOverlapped* = ref CustomOverlapped