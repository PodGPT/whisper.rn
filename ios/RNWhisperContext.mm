#import "RNWhisperContext.h"

#define NUM_BYTES_PER_BUFFER 16 * 1024

@implementation RNWhisperContext

+ (instancetype)initWithModelPath:(NSString *)modelPath {
    RNWhisperContext *context = [[RNWhisperContext alloc] init];
    context->ctx = whisper_init_from_file([modelPath UTF8String]);
    return context;
}

- (struct whisper_context *)getContext {
    return self->ctx;
}

- (void)prepareRealtime:(NSDictionary *)options {
    self->recordState.options = options;

    self->recordState.dataFormat.mSampleRate = WHISPER_SAMPLE_RATE; // 16000
    self->recordState.dataFormat.mFormatID = kAudioFormatLinearPCM;
    self->recordState.dataFormat.mFramesPerPacket = 1;
    self->recordState.dataFormat.mChannelsPerFrame = 1; // mono
    self->recordState.dataFormat.mBytesPerFrame = 2;
    self->recordState.dataFormat.mBytesPerPacket = 2;
    self->recordState.dataFormat.mBitsPerChannel = 16;
    self->recordState.dataFormat.mReserved = 0;
    self->recordState.dataFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger;

    int maxAudioSecOpt = options[@"realtimeAudioSec"] != nil ? [options[@"realtimeAudioSec"] intValue] : 0;
    int maxAudioSec = maxAudioSecOpt > 0 ? maxAudioSecOpt : DEFAULT_MAX_AUDIO_SEC;
    self->recordState.maxAudioSec = maxAudioSec;

    int realtimeAudioSliceSec = options[@"realtimeAudioSliceSec"] != nil ? [options[@"realtimeAudioSliceSec"] intValue] : 0;
    int audioSliceSec = realtimeAudioSliceSec > 0 && realtimeAudioSliceSec < maxAudioSec ? realtimeAudioSliceSec : maxAudioSec;

    self->recordState.audioSliceSec = audioSliceSec;
    self->recordState.isUseSlices = audioSliceSec < maxAudioSec;

    self->recordState.sliceIndex = 0;
    self->recordState.transcribeSliceIndex = 0;
    self->recordState.nSamplesTranscribing = 0;

    [self freeBufferIfNeeded];
    self->recordState.shortBufferSlices = [NSMutableArray new];

    int16_t *audioBufferI16 = (int16_t *) malloc(audioSliceSec * WHISPER_SAMPLE_RATE * sizeof(int16_t));
    [self->recordState.shortBufferSlices addObject:[NSValue valueWithPointer:audioBufferI16]];

    self->recordState.sliceNSamples = [NSMutableArray new];
    [self->recordState.sliceNSamples addObject:[NSNumber numberWithInt:0]];

    self->recordState.isRealtime = true;
    self->recordState.isTranscribing = false;
    self->recordState.isCapturing = false;
    self->recordState.isStoppedByAction = false;

    self->recordState.mSelf = self;
}

- (void)freeBufferIfNeeded {
    if (self->recordState.shortBufferSlices != nil) {
        for (int i = 0; i < [self->recordState.shortBufferSlices count]; i++) {
            int16_t *audioBufferI16 = (int16_t *) [self->recordState.shortBufferSlices[i] pointerValue];
            free(audioBufferI16);
        }
        self->recordState.shortBufferSlices = nil;
    }
}

void AudioInputCallback(void * inUserData,
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    const AudioTimeStamp * inStartTime,
    UInt32 inNumberPacketDescriptions,
    const AudioStreamPacketDescription * inPacketDescs)
{
    RNWhisperContextRecordState *state = (RNWhisperContextRecordState *)inUserData;

    if (!state->isCapturing) {
        NSLog(@"[RNWhisper] Not capturing, ignoring audio");
        if (!state->isTranscribing) {
            state->transcribeHandler(state->jobId, @"end", @{});
        }
        return;
    }

    int totalNSamples = 0;
    for (int i = 0; i < [state->sliceNSamples count]; i++) {
        totalNSamples += [[state->sliceNSamples objectAtIndex:i] intValue];
    }

    const int n = inBuffer->mAudioDataByteSize / 2;

    int nSamples = [state->sliceNSamples[state->sliceIndex] intValue];

    if (totalNSamples + n > state->maxAudioSec * WHISPER_SAMPLE_RATE) {
        NSLog(@"[RNWhisper] Audio buffer is full, stop capturing");
        state->isCapturing = false;
        [state->mSelf stopAudio];
        if (
            !state->isTranscribing &&
            nSamples == state->nSamplesTranscribing &&
            state->sliceIndex == state->transcribeSliceIndex
        ) {
            state->transcribeHandler(state->jobId, @"end", @{});
        } else if (
            !state->isTranscribing &&
            nSamples != state->nSamplesTranscribing
        ) {
            state->isTranscribing = true;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [state->mSelf fullTranscribeSamples:state];
            });
        }
        return;
    }

    int audioSliceSec = state->audioSliceSec;
    if (nSamples + n > audioSliceSec * WHISPER_SAMPLE_RATE) {
        // next slice
        state->sliceIndex++;
        nSamples = 0;
        int16_t* audioBufferI16 = (int16_t*) malloc(audioSliceSec * WHISPER_SAMPLE_RATE * sizeof(int16_t));
        [state->shortBufferSlices addObject:[NSValue valueWithPointer:audioBufferI16]];
        [state->sliceNSamples addObject:[NSNumber numberWithInt:0]];
    }

    // Append to buffer
    NSLog(@"[RNWhisper] Slice %d has %d samples", state->sliceIndex, nSamples);

    int16_t* audioBufferI16 = (int16_t*) [state->shortBufferSlices[state->sliceIndex] pointerValue];
    for (int i = 0; i < n; i++) {
        audioBufferI16[nSamples + i] = ((short*)inBuffer->mAudioData)[i];
    }
    nSamples += n;
    state->sliceNSamples[state->sliceIndex] = [NSNumber numberWithInt:nSamples];

    AudioQueueEnqueueBuffer(state->queue, inBuffer, 0, NULL);

    if (!state->isTranscribing) {
        state->isTranscribing = true;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [state->mSelf fullTranscribeSamples:state];
        });
    }
}

- (void)fullTranscribeSamples:(RNWhisperContextRecordState*) state {
    int nSamplesOfIndex = [[state->sliceNSamples objectAtIndex:state->transcribeSliceIndex] intValue];
    state->nSamplesTranscribing = nSamplesOfIndex;
    NSLog(@"[RNWhisper] Transcribing %d samples", state->nSamplesTranscribing);

    int16_t* audioBufferI16 = (int16_t*) [state->shortBufferSlices[state->transcribeSliceIndex] pointerValue];
    float* audioBufferF32 = (float*) malloc(state->nSamplesTranscribing * sizeof(float));
    // convert I16 to F32
    for (int i = 0; i < state->nSamplesTranscribing; i++) {
        audioBufferF32[i] = (float)audioBufferI16[i] / 32768.0f;
    }
    CFTimeInterval timeStart = CACurrentMediaTime();
    int code = [state->mSelf fullTranscribe:state->jobId audioData:audioBufferF32 audioDataCount:state->nSamplesTranscribing options:state->options];
    free(audioBufferF32);
    CFTimeInterval timeEnd = CACurrentMediaTime();
    const float timeRecording = (float) state->nSamplesTranscribing / (float) state->dataFormat.mSampleRate;

    NSDictionary* base = @{
        @"code": [NSNumber numberWithInt:code],
        @"processTime": [NSNumber numberWithInt:(timeEnd - timeStart) * 1E3],
        @"recordingTime": [NSNumber numberWithInt:timeRecording * 1E3],
        @"isUseSlices": @(state->isUseSlices),
        @"sliceIndex": @(state->transcribeSliceIndex),
    };

    NSMutableDictionary* result = [base mutableCopy];

    if (code == 0) {
        result[@"data"] = [state->mSelf getTextSegments];
    } else {
        result[@"error"] = [NSString stringWithFormat:@"Transcribe failed with code %d", code];
    }

    nSamplesOfIndex = [[state->sliceNSamples objectAtIndex:state->transcribeSliceIndex] intValue];
    if (
        state->isStoppedByAction ||
        (
            !state->isCapturing &&
            state->nSamplesTranscribing == nSamplesOfIndex &&
            state->sliceIndex == state->transcribeSliceIndex
        )
    ) {
        NSLog(@"[RNWhisper] Transcribe end");
        result[@"isStoppedByAction"] = @(state->isStoppedByAction);
        result[@"isCapturing"] = @(false);
        state->transcribeHandler(state->jobId, @"end", result);
    } else if (code == 0) {
        result[@"isCapturing"] = @(true);
        state->transcribeHandler(state->jobId, @"transcribe", result);
    } else {
        result[@"isCapturing"] = @(true);
        state->transcribeHandler(state->jobId, @"transcribe", result);
    }

    if (
      // If no more samples on current slice, move to next slice
      state->nSamplesTranscribing == nSamplesOfIndex &&
      state->transcribeSliceIndex != state->sliceIndex
    ) {
        state->transcribeSliceIndex++;
        state->nSamplesTranscribing = 0;
    }

    if (
        !state->isCapturing &&
        state->nSamplesTranscribing != nSamplesOfIndex
    ) {
        state->isTranscribing = true;
        // Finish transcribing the rest of the samples
        [self fullTranscribeSamples:state];
    }
    state->isTranscribing = false;
}

- (bool)isCapturing {
    return self->recordState.isCapturing;
}

- (bool)isTranscribing {
    return self->recordState.isTranscribing;
}

- (OSStatus)transcribeRealtime:(int)jobId
    options:(NSDictionary *)options
    onTranscribe:(void (^)(int, NSString *, NSDictionary *))onTranscribe
{
    self->recordState.transcribeHandler = onTranscribe;
    self->recordState.jobId = jobId;
    [self prepareRealtime:options];

    OSStatus status = AudioQueueNewInput(
        &self->recordState.dataFormat,
        AudioInputCallback,
        &self->recordState,
        NULL,
        kCFRunLoopCommonModes,
        0,
        &self->recordState.queue
    );

    if (status == 0) {
        for (int i = 0; i < NUM_BUFFERS; i++) {
            AudioQueueAllocateBuffer(self->recordState.queue, NUM_BYTES_PER_BUFFER, &self->recordState.buffers[i]);
            AudioQueueEnqueueBuffer(self->recordState.queue, self->recordState.buffers[i], 0, NULL);
        }
        status = AudioQueueStart(self->recordState.queue, NULL);
        if (status == 0) {
            self->recordState.isCapturing = true;
        }
    }
    return status;
}

- (int)transcribeFile:(int)jobId
    audioData:(float *)audioData
    audioDataCount:(int)audioDataCount
    options:(NSDictionary *)options
{
    self->recordState.isTranscribing = true;
    self->recordState.jobId = jobId;
    int code = [self fullTranscribe:jobId audioData:audioData audioDataCount:audioDataCount options:options];
    self->recordState.jobId = -1;
    self->recordState.isTranscribing = false;
    return code;
}

- (void)stopAudio {
    AudioQueueStop(self->recordState.queue, true);
    for (int i = 0; i < NUM_BUFFERS; i++) {
        AudioQueueFreeBuffer(self->recordState.queue, self->recordState.buffers[i]);
    }
    AudioQueueDispose(self->recordState.queue, true);
}

- (void)stopTranscribe:(int)jobId {
    rn_whisper_abort_transcribe(jobId);
    if (!self->recordState.isRealtime || !self->recordState.isCapturing) {
        return;
    }
    self->recordState.isTranscribing = false;
    self->recordState.isCapturing = false;
    self->recordState.isStoppedByAction = true;
    [self stopAudio];
}

- (void)stopCurrentTranscribe {
    if (!self->recordState.jobId) {
        return;
    }
    [self stopTranscribe:self->recordState.jobId];
}

- (int)fullTranscribe:(int)jobId audioData:(float *)audioData audioDataCount:(int)audioDataCount options:(NSDictionary *)options {
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

    const int max_threads = options[@"maxThreads"] != nil ?
      [options[@"maxThreads"] intValue] :
      MIN(4, (int)[[NSProcessInfo processInfo] processorCount]);

    if (options[@"beamSize"] != nil) {
        params.strategy = WHISPER_SAMPLING_BEAM_SEARCH;
        params.beam_search.beam_size = [options[@"beamSize"] intValue];
    }

    params.print_realtime   = false;
    params.print_progress   = false;
    params.print_timestamps = false;
    params.print_special    = false;
    params.speed_up         = options[@"speedUp"] != nil ? [options[@"speedUp"] boolValue] : false;
    params.translate        = options[@"translate"] != nil ? [options[@"translate"] boolValue] : false;
    params.language         = options[@"language"] != nil ? [options[@"language"] UTF8String] : "auto";
    params.n_threads        = max_threads;
    params.offset_ms        = 0;
    params.no_context       = true;
    params.single_segment   = false;

    if (options[@"maxLen"] != nil) {
        params.max_len = [options[@"maxLen"] intValue];
    }
    params.token_timestamps = options[@"tokenTimestamps"] != nil ? [options[@"tokenTimestamps"] boolValue] : false;

    if (options[@"bestOf"] != nil) {
        params.greedy.best_of = [options[@"bestOf"] intValue];
    }
    if (options[@"maxContext"] != nil) {
        params.n_max_text_ctx = [options[@"maxContext"] intValue];
    }
    
    if (options[@"offset"] != nil) {
        params.offset_ms = [options[@"offset"] intValue];
    }
    if (options[@"duration"] != nil) {
        params.duration_ms = [options[@"duration"] intValue];
    }
    if (options[@"wordThold"] != nil) {
        params.thold_pt = [options[@"wordThold"] intValue];
    }
    if (options[@"temperature"] != nil) {
        params.temperature = [options[@"temperature"] floatValue];
    }
    if (options[@"temperatureInc"] != nil) {
        params.temperature_inc = [options[@"temperature_inc"] floatValue];
    }
    
    if (options[@"prompt"] != nil) {
        std::string *prompt = new std::string([options[@"prompt"] UTF8String]);
        rn_whisper_convert_prompt(
            self->ctx,
            params,
            prompt
        );
    }

    params.encoder_begin_callback = [](struct whisper_context * /*ctx*/, struct whisper_state * /*state*/, void * user_data) {
        bool is_aborted = *(bool*)user_data;
        return !is_aborted;
    };
    params.encoder_begin_callback_user_data = rn_whisper_assign_abort_map(jobId);

    whisper_reset_timings(self->ctx);

    int code = whisper_full(self->ctx, params, audioData, audioDataCount);
    rn_whisper_remove_abort_map(jobId);
    // if (code == 0) {
    //     whisper_print_timings(self->ctx);
    // }
    return code;
}

- (NSDictionary *)getTextSegments {
    NSString *result = @"";
    int n_segments = whisper_full_n_segments(self->ctx);

    NSMutableArray *segments = [[NSMutableArray alloc] init];
    for (int i = 0; i < n_segments; i++) {
        const char * text_cur = whisper_full_get_segment_text(self->ctx, i);
        result = [result stringByAppendingString:[NSString stringWithUTF8String:text_cur]];

        const int64_t t0 = whisper_full_get_segment_t0(self->ctx, i);
        const int64_t t1 = whisper_full_get_segment_t1(self->ctx, i);
        NSDictionary *segment = @{
            @"text": [NSString stringWithUTF8String:text_cur],
            @"t0": [NSNumber numberWithLongLong:t0],
            @"t1": [NSNumber numberWithLongLong:t1]
        };
        [segments addObject:segment];
    }
    return @{
        @"result": result,
        @"segments": segments
    };
}

- (void)invalidate {
    [self stopCurrentTranscribe];
    whisper_free(self->ctx);
    [self freeBufferIfNeeded];
}

@end
