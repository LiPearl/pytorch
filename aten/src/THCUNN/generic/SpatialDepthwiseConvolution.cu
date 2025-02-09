#ifndef THC_GENERIC_FILE
#define THC_GENERIC_FILE "THCUNN/generic/SpatialDepthwiseConvolution.cu"
#else


void THNN_(SpatialDepthwiseConvolution_updateOutput)(
                  THCState *state,
                  THCTensor *input,
                  THCTensor *output,
                  THCTensor *weight,
                  THCTensor *bias,
                  int kW, int kH,
                  int dW, int dH,
                  int padW, int padH,
                  int dilationW, int dilationH)
{
  //******Using padH to represent sumChannels
  int sumChannels = 1;
  if (padH != padW){
    sumChannels = padW;
    padW = padH;
  }
  int outputChannels = weight->size(0);

  //******calculate the real outputChannels
  outputChannels = outputChannels / sumChannels;

  THCUNN_assertSameGPU(state, 3, input, output, weight);

  // Only handle 4D Input Tensors for now
  THAssert(!input->is_empty() && THCTensor_(nDimensionLegacyNoScalars)(state, input) == 4);
  THAssert(!weight->is_empty() && THCTensor_(nDimensionLegacyNoScalars)(state, weight) == 4);

  // We assume that the input and weight Tensors are shaped properly by
  // the caller, so we verify that here to some extent

  // Weight Tensor is shape (output_channels, 1, kH, kW)
  THAssert(weight->size(1) == 1);

  // Input Tensor is shape (N, input_channels, H, W)
  // We verify that the # of output_channels is a multiple of input_channels
  THAssert(weight->size(0) % input->size(1) == 0);

  // Bias has same # of channels as output
  if (bias) {
    THAssert(THTensor_sizeLegacyNoScalars(bias, 0) == outputChannels);
  }

  input = THCTensor_(newContiguous)(state, input);
  weight = THCTensor_(newContiguous)(state, weight);
  bias = bias ? THCTensor_(newContiguous)(state, bias) : bias;

  // Following the behvaior of other THCUNN functions, we shape the output
  // Tensor ourselves

  int batchSize = input->size(0);
  int height = input->size(2);
  int width = input->size(3);
  int outputHeight = (height + 2 * padH - (dilationH * (kH - 1) + 1)) / dH + 1;
  int outputWidth = (width + 2 * padW - (dilationW * (kW - 1) + 1)) / dW + 1;
  

  THCTensor_(resize4d)(state, output, batchSize, outputChannels, outputHeight, outputWidth);

  // Create THCDeviceTensor
  // Kernel currently relies upon all the Tensors to be contiguous, but we made
  // them contiguous above
  THCDeviceTensor<scalar_t, 4> dInput = toDeviceTensor<scalar_t, 4>(state, input);
  THCDeviceTensor<scalar_t, 4> dWeight = toDeviceTensor<scalar_t, 4>(state, weight);
  THCDeviceTensor<scalar_t, 4> dOutput = toDeviceTensor<scalar_t, 4>(state, output);
  THCDeviceTensor<scalar_t, 1> dBias;
  if (bias) {
    dBias = toDeviceTensor<scalar_t, 1>(state, bias);
  }

  int inputChannels = input->size(1);
  float depthwiseMultiplier = 1.0 * outputChannels / inputChannels;

  // One thread per output value
  int n = THCTensor_(nElement)(state, output);
  int blocks = GET_BLOCKS(n);
  dim3 grid(blocks);
  dim3 block(CUDA_NUM_THREADS);
  if (kW == 3 && kH == 3) {
  spatialDepthwiseConvolutionUpdateOutput<scalar_t, accreal, unsigned int, 3><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
    dInput, dOutput, dWeight, dBias, bias != NULL, n, inputChannels, outputChannels, depthwiseMultiplier,
    width, height, outputWidth, outputHeight,
    kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
  } else if (kW == 1 && kH == 1) {
  spatialDepthwiseConvolutionUpdateOutput<scalar_t, accreal, unsigned int, 1><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
    dInput, dOutput, dWeight, dBias, bias != NULL, n, inputChannels, outputChannels, depthwiseMultiplier,
    width, height, outputWidth, outputHeight,
    kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
  } else {
  spatialDepthwiseConvolutionUpdateOutput<scalar_t, accreal, unsigned int, 0><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
    dInput, dOutput, dWeight, dBias, bias != NULL, n, inputChannels, outputChannels, depthwiseMultiplier,
    width, height, outputWidth, outputHeight,
    kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
  }

  THCudaCheck(cudaGetLastError());

  THCTensor_(free)(state, input);
  THCTensor_(free)(state, weight);
  if (bias) THCTensor_(free)(state, bias);
}

void THNN_(SpatialDepthwiseConvolution_updateGradInput)(
                  THCState *state,
                  THCTensor *input,
                  THCTensor *gradOutput,
                  THCTensor *gradInput,
                  THCTensor *weight,
                  int kW, int kH,
                  int dW, int dH,
                  int padW, int padH,
                  int dilationW, int dilationH)
{
  //******Using padH to represent sumChannels
  int sumChannels = 1;
  if (padH != padW){
    sumChannels = padW;
    padW = padH;
  }

  THCUNN_assertSameGPU(state, 3, gradOutput, gradInput, weight);

  // Only handle 4D Input Tensors for now
  THAssert(!input->is_empty() && THCTensor_(nDimensionLegacyNoScalars)(state, input) == 4);
  THAssert(!weight->is_empty() && THCTensor_(nDimensionLegacyNoScalars)(state, weight) == 4);
  THAssert(!gradOutput->is_empty() && THCTensor_(nDimensionLegacyNoScalars)(state, gradOutput) == 4);

  // Minimal shape checking, as above
  // Same # of elements in batch
  THAssert(input->size(0) == gradOutput->size(0));
  // Same # of filters as outputChannels
  THAssert(weight->size(0)/sumChannels == gradOutput->size(1));

  weight = THCTensor_(newContiguous)(state, weight);
  gradOutput = THCTensor_(newContiguous)(state, gradOutput);


  // Resize GradInput
  THCTensor_(resizeAs)(state, gradInput, input);

  int inputChannels = input->size(1);
  int height = input->size(2);
  int width = input->size(3);

  int outputChannels = gradOutput->size(1);
  int outputHeight = gradOutput->size(2);
  int outputWidth = gradOutput->size(3);

  float depthwiseMultiplier = (float)outputChannels / inputChannels;

  THCDeviceTensor<scalar_t, 4> dGradOutput = toDeviceTensor<scalar_t, 4>(state, gradOutput);
  THCDeviceTensor<scalar_t, 4> dGradInput = toDeviceTensor<scalar_t, 4>(state, gradInput);
  THCDeviceTensor<scalar_t, 4> dWeight = toDeviceTensor<scalar_t, 4>(state, weight);

  // Kernel currently relies upon all the Tensors to be contiguous
  THAssert(dGradOutput.isContiguous());
  THAssert(dGradInput.isContiguous());
  THAssert(dWeight.isContiguous());

  // One thread per gradInput value
  int n = THCTensor_(nElement)(state, gradInput);
  int blocks = GET_BLOCKS(n);
  dim3 grid(blocks);
  dim3 block(CUDA_NUM_THREADS);
  if (kW == 3 && kH == 3)
    if (dW == 1 && dH == 1){
      spatialDepthwiseConvolutionUpdateGradInput<scalar_t, accreal, unsigned int, 3, 1><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
      dGradOutput, dGradInput, dWeight, n, inputChannels, outputChannels, depthwiseMultiplier, width,
      height, outputWidth, outputHeight, kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
    } else if (dW == 2 && dH == 2) {
      spatialDepthwiseConvolutionUpdateGradInput<scalar_t, accreal, unsigned int, 3, 2><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
      dGradOutput, dGradInput, dWeight, n, inputChannels, outputChannels, depthwiseMultiplier, width,
      height, outputWidth, outputHeight, kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
    } else {
      spatialDepthwiseConvolutionUpdateGradInput<scalar_t, accreal, unsigned int, 3, 0><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
      dGradOutput, dGradInput, dWeight, n, inputChannels, outputChannels, depthwiseMultiplier, width,
      height, outputWidth, outputHeight, kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
    }
  else if (kW == 1 && kH == 1)
    if (dW == 1 && dH == 1){
      spatialDepthwiseConvolutionUpdateGradInput<scalar_t, accreal, unsigned int, 1, 1><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
      dGradOutput, dGradInput, dWeight, n, inputChannels, outputChannels, depthwiseMultiplier, width,
      height, outputWidth, outputHeight, kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
    } else if (dW == 2 && dH == 2) {
      spatialDepthwiseConvolutionUpdateGradInput<scalar_t, accreal, unsigned int, 1, 2><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
      dGradOutput, dGradInput, dWeight, n, inputChannels, outputChannels, depthwiseMultiplier, width,
      height, outputWidth, outputHeight, kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
    } else {
      spatialDepthwiseConvolutionUpdateGradInput<scalar_t, accreal, unsigned int, 1, 0><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
      dGradOutput, dGradInput, dWeight, n, inputChannels, outputChannels, depthwiseMultiplier, width,
      height, outputWidth, outputHeight, kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
    }
  else
    if (dW == 1 && dH == 1){
      spatialDepthwiseConvolutionUpdateGradInput<scalar_t, accreal, unsigned int, 0, 1><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
      dGradOutput, dGradInput, dWeight, n, inputChannels, outputChannels, depthwiseMultiplier, width,
      height, outputWidth, outputHeight, kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
    } else if (dW == 2 && dH == 2) {
      spatialDepthwiseConvolutionUpdateGradInput<scalar_t, accreal, unsigned int, 0, 2><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
      dGradOutput, dGradInput, dWeight, n, inputChannels, outputChannels, depthwiseMultiplier, width,
      height, outputWidth, outputHeight, kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
    } else {
      spatialDepthwiseConvolutionUpdateGradInput<scalar_t, accreal, unsigned int, 0, 0><<<grid, block, 0, THCState_getCurrentStream(state)>>>(
      dGradOutput, dGradInput, dWeight, n, inputChannels, outputChannels, depthwiseMultiplier, width,
      height, outputWidth, outputHeight, kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);
    }


  THCudaCheck(cudaGetLastError());

  THCTensor_(free)(state, weight);
  THCTensor_(free)(state, gradOutput);
}

void THNN_(SpatialDepthwiseConvolution_accGradParameters)(
                  THCState *state,
                  THCTensor *input,
                  THCTensor *gradOutput,
                  THCTensor *gradWeight,
                  int kW, int kH,
                  int dW, int dH,
                  int padW, int padH,
                  int dilationW, int dilationH)
{
  //******Using padH to represent sumChannels
  int sumChannels = 1;
  if (padH != padW){
    sumChannels = padW;
    padW = padH;
  }

  THCUNN_assertSameGPU(state, 3, input, gradOutput, gradWeight);

  // Only handle 4D Input Tensors for now
  THAssert(!input->is_empty() && THCTensor_(nDimensionLegacyNoScalars)(state, input) == 4);
  THAssert(!gradOutput->is_empty() && THCTensor_(nDimensionLegacyNoScalars)(state, gradOutput) == 4);
  THAssert(!gradWeight->is_empty() && THCTensor_(nDimensionLegacyNoScalars)(state, gradWeight) == 4);

  // Minimal shape checking as above
  // Same # of elements in batch
  THAssert(input->size(0) == gradOutput->size(0));
  // Same # of filters as outputChannels
  THAssert(gradWeight->size(0)/sumChannels == gradOutput->size(1));

  int batchSize = input->size(0);
  int inputChannels = input->size(1);
  int height = input->size(2);
  int width = input->size(3);

  int outputChannels = gradOutput->size(1);
  int outputHeight = gradOutput->size(2);
  int outputWidth = gradOutput->size(3);

  float depthwiseMultiplier = (float)outputChannels / inputChannels;

  gradOutput = THCTensor_(newContiguous)(state, gradOutput);

  THCDeviceTensor<scalar_t, 4> dGradOutput = toDeviceTensor<scalar_t, 4>(state, gradOutput);
  THCDeviceTensor<scalar_t, 4> dInput = toDeviceTensor<scalar_t, 4>(state, input);
  THCDeviceTensor<scalar_t, 4> dGradWeight = toDeviceTensor<scalar_t, 4>(state, gradWeight);

  // Kernel currently relies upon all the Tensors to be contiguous
  THAssert(dGradOutput.isContiguous());
  THAssert(dInput.isContiguous());
  THAssert(dGradWeight.isContiguous());

  // We parallelize so that each block computes a single value in gradWeight
  int blocks = outputChannels * kH * kW * sumChannels;


  // Make sure we have enough threads to perform the reduction, and use this number
  // to create the shared memory size for the reduction
  dim3 grid(blocks);
  dim3 block(getGradParamsNumThreads(batchSize));
  int smem = block.x * sizeof(accreal);

  spatialDepthwiseConvolutionAccGradParameters<scalar_t, accreal, unsigned int><<<grid, block, smem, THCState_getCurrentStream(state)>>>(
      dGradOutput, dInput, dGradWeight, batchSize, inputChannels, outputChannels, depthwiseMultiplier,
      width, height, outputWidth, outputHeight, kW, kH, dW, dH, padW, padH, dilationW, dilationH, sumChannels);

  THCudaCheck(cudaGetLastError());

  THCTensor_(free)(state, gradOutput);
}

#endif
