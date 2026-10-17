"""Corpus citations, RULINGS.md R1; consumer support is distinguished from corroboration."""

CITATIONS = {'DOP_MARKER_ALT': {'doc': 'dop-1.1',
                    'section': '2',
                    'page': 2,
                    'tier': 'primary',
                    'quote': 'alternate with each sample between 0x05 and 0xFA',
                    'note': 'Only marker values and alternation are normative here. Requested initial phase '
                            'and default 0x05 are interface requirements in stub/vblind.py dop_pack; the '
                            'standard does not prescribe a default phase.'},
 'DOP_MARKER_SAME': {'doc': 'dop-1.1',
                     'section': '2',
                     'page': 2,
                     'tier': 'primary',
                     'quote': 'Each channel within a sample contains the same marker.',
                     'note': 'Every channel of one PCM frame carries the same marker.'},
 'DOP_MARKER_MSB': {'doc': 'dop-1.1',
                    'section': '2',
                    'page': 2,
                    'tier': 'primary',
                    'quote': 'The 8 most significant bits are used for the DSD marker',
                    'note': 'Marker occupies bits 23..16 of the 24-bit word.'},
 'DOP_BITS_OLDEST': {'doc': 'dop-1.1',
                     'section': '2',
                     'page': 2,
                     'tier': 'primary',
                     'quote': 'The remaining 16 lower bits are then used for the DSD data, first or oldest '
                              'bit in slot t0.',
                     'note': '16 DSD bits in the lower 16 bits, oldest bit in slot t0.'},
 'DOP_DIAGRAM': {'doc': 'dop-1.1',
                 'section': '2',
                 'page': 2,
                 'tier': 'primary',
                 'quote': 'dm0 t0 t1 t2 t3 t4 t5 t6 t7 t8',
                 'note': 'Diagram: t0 sits directly below the marker, i.e. at the most significant end of '
                         'the 16 DSD bits; t1.. follow towards the LSB.'},
 'DOP_24BIT': {'doc': 'dop-1.1',
               'section': '2',
               'page': 2,
               'tier': 'primary',
               'quote': 'MSB 24 bit PCM Frame LSB',
               'note': 'The DoP sample word is 24 bits wide (8 marker + 16 DSD).'},
 'DOP_PER_CHANNEL': {'doc': 'dop-1.1',
                     'section': '2',
                     'page': 2,
                     'tier': 'primary',
                     'quote': 'for DSD streaming each PCM Frame contains only DSD data corresponding to its '
                              'assigned channel.',
                     'note': 'Each PCM channel of a frame carries only its own DSD channel.'},
 'DOP_OTHER_MARKER': {'doc': 'dop-1.1',
                      'section': '3',
                      'page': 2,
                      'tier': 'primary',
                      'quote': 'A different marker byte is used to distinguish this method from the first '
                               'one.',
                      'note': '0x06/0xF9 belong to the (out of scope) paired-channel method, so they are not '
                              'markers of the base method.'},
 'DOP_ALT_MARKERS': {'doc': 'dop-1.1',
                     'section': '3',
                     'page': 2,
                     'tier': 'primary',
                     'quote': 'PCM frame 1 => 0x06 16 DSD bits ch1 0xF9 16 DSD bits ch1 0x06 16 DSD bits ch1',
                     'note': 'The paired-channel method uses markers 0x06/0xF9, not those of the base '
                             'method.'},
 'DOP_RX_MISSING': {'doc': 'dop-1.1',
                    'section': '4',
                    'page': 3,
                    'tier': 'primary',
                    'quote': 'the receiver has to detect at least 1 single missing DSD marker byte in at '
                             'least 1 channel.',
                    'note': 'A frame in which one channel lacks the DSD marker is not DSD (PCM): not a valid '
                            'DoP stream.'},
 'ST337_PA': {'doc': 'smpte-st337-2015',
              'section': '7.2.1',
              'page': 9,
              'tier': 'sibling-standard',
              'quote': '= 0xF872 (16-bit mode)',
              'note': 'Pa sync word, 16-bit mode. Carries over to the consumer format: ST337 8.2 calls the '
                      'consumer stream a subset of this format, and 8.3 restricts compatible bursts to '
                      '16-bit frame mode.'},
 'ST337_PB': {'doc': 'smpte-st337-2015',
              'section': '7.2.1',
              'page': 9,
              'tier': 'sibling-standard',
              'quote': '= 0x4E1F (16-bit mode)',
              'note': 'Pb sync word, 16-bit mode (same applicability argument as ST337_PA).'},
 'ST337_EXT_SYNC': {'doc': 'smpte-st337-2015',
                    'section': '7.4',
                    'page': 13,
                    'tier': 'sibling-standard',
                    'quote': '0x0000, 0x0000, 0x0000, 0x0000, 0xF872, 0x4E1F',
                    'note': 'Pa, Pb in 16-bit mode are 0xF872, 0x4E1F, preceded by four zero words in the '
                            'extended sync code.'},
 'ST337_FRAME_PRE': {'doc': 'smpte-st337-2015',
                     'section': '7.2.2',
                     'page': 9,
                     'tier': 'sibling-standard',
                     'quote': 'The frame beginning the data burst shall contain preamble word Pa in the Ch1 '
                              'subframe, and Pb in the Ch2 subframe. The next frame shall contain Pc in Ch1 '
                              'and Pd in Ch2.',
                     'note': 'Placement of Pa..Pd in the first two frames, frame mode. Consumer interface '
                             'uses frame mode (ST337 8.3).'},
 'ST337_CONSUMER_SUBSET': {'doc': 'smpte-st337-2015',
                           'section': '8.2',
                           'page': 14,
                           'tier': 'sibling-standard',
                           'quote': 'The consumer bit stream format can, in general, be considered a subset '
                                    'of the professional bit stream format defined by this standard.',
                           'note': 'Why the burst-structure rules of ST337 carry over to the consumer '
                                   'format.'},
 'ST337_CONSUMER_16': {'doc': 'smpte-st337-2015',
                       'section': '8.3',
                       'page': 14,
                       'tier': 'sibling-standard',
                       'quote': 'all data bursts are restricted to the 16-bit frame mode (data_mode=0, both '
                                'AES3-3 subframes used).',
                       'note': 'Consumer-compatible bursts are 16-bit frame mode with data_mode 0.'},
 'ST337_PRE_FOLLOW': {'doc': 'smpte-st337-2015',
                      'section': '7.1',
                      'page': 8,
                      'tier': 'sibling-standard',
                      'quote': 'Each data burst shall consist of a burst_preamble followed by a '
                               'burst_payload.',
                      'note': 'Payload follows the preamble directly (common burst structure).'},
 'ST337_T7_TYPE': {'doc': 'smpte-st337-2015',
                   'section': '7.2.4.1',
                   'page': 10,
                   'tier': 'sibling-standard',
                   'quote': '8-12 4-8 0-4 data_type (5-bit unsigned integer = 0 to 31)',
                   'note': 'In the 16-bit mode data_type is bits 0-4 of Pc. Consumer carryover inference: '
                           'ST337 8.2 describes shared burst preambles and extracting consumer bursts; 8.3 '
                           'restricts compatibility to 16-bit frame mode. This supports field positions, not '
                           'type-dependent contents (8.4).'},
 'ST337_T7_MODE': {'doc': 'smpte-st337-2015',
                   'section': '7.2.4.1',
                   'page': 10,
                   'tier': 'sibling-standard',
                   'quote': '13-14 9-10 5-6 data_mode',
                   'note': 'data_mode is bits 5-6 of Pc in the 16-bit mode. Consumer carryover inference: '
                           'ST337 8.2 describes shared burst preambles and extracting consumer bursts; 8.3 '
                           'restricts compatibility to 16-bit frame mode. This supports field positions, not '
                           'type-dependent contents (8.4).'},
 'ST337_T7_ERR': {'doc': 'smpte-st337-2015',
                  'section': '7.2.4.1',
                  'page': 10,
                  'tier': 'sibling-standard',
                  'quote': '15 11 7 0 indicates data may be valid.',
                  'note': 'error_flag is bit 7 of Pc in the 16-bit mode. Consumer carryover inference: ST337 '
                          '8.2 describes shared burst preambles and extracting consumer bursts; 8.3 '
                          'restricts compatibility to 16-bit frame mode. This supports field positions, not '
                          'type-dependent contents (8.4).'},
 'ST337_T7_DTD': {'doc': 'smpte-st337-2015',
                  'section': '7.2.4.1',
                  'page': 10,
                  'tier': 'sibling-standard',
                  'quote': '16-20 12-16 8-12 data_type_dependent',
                  'note': 'data_type_dependent is bits 8-12 of Pc in the 16-bit mode. Consumer carryover '
                          'inference: ST337 8.2 describes shared burst preambles and extracting consumer '
                          'bursts; 8.3 restricts compatibility to 16-bit frame mode. This supports field '
                          'positions, not type-dependent contents (8.4).'},
 'ST337_T7_STREAM': {'doc': 'smpte-st337-2015',
                     'section': '7.2.4.1',
                     'page': 10,
                     'tier': 'sibling-standard',
                     'quote': '21-23 17-19 13-15 data_stream_number',
                     'note': 'data_stream_number is bits 13-15 of Pc in the 16-bit mode. Consumer carryover '
                             'inference: ST337 8.2 describes shared burst preambles and extracting consumer '
                             'bursts; 8.3 restricts compatibility to 16-bit frame mode. This supports field '
                             'positions, not type-dependent contents (8.4).'},
 'ST337_T8_16': {'doc': 'smpte-st337-2015',
                 'section': '7.2.4.3',
                 'page': 11,
                 'tier': 'sibling-standard',
                 'quote': '0 16-bit mode Subframe time slots 27-12',
                 'note': 'data_mode value 0 = 16-bit mode.'},
 'ST337_ERR0': {'doc': 'smpte-st337-2015',
                'section': '7.2.4.4',
                'page': 11,
                'tier': 'sibling-standard',
                'quote': 'If the data in the burst_payload is known to be error free or if it is unknown '
                         'whether the data contains errors, then the value of this bit shall be set to a '
                         '‘0’.',
                'note': 'Unknown payload errors imply error_flag 0. Consumer carryover inference: 8.2 shared '
                        'preamble extraction and 8.3 16-bit frame mode; unlike dependent-field coding, 8.4 '
                        'does not identify a different error-flag meaning.'},
 'ST337_STREAM0': {'doc': 'smpte-st337-2015',
                   'section': '7.2.4.6',
                   'page': 12,
                   'tier': 'sibling-standard',
                   'quote': 'At least one bit stream having data_stream_number = 0 shall be present.',
                   'note': 'The single stream of a one-stream interface is stream 0 (the scope fixes one '
                           'stream, number 0).'},
 'ST337_LEN_BITS': {'doc': 'smpte-st337-2015',
                    'section': '7.2.5',
                    'page': 12,
                    'tier': 'sibling-standard',
                    'quote': 'The length_code shall indicate the length of the burst_payload in bits.',
                    'note': 'Professional bits unit only. Consumer even-byte AC-3/DTS unit is supported '
                            'independently by FF_LEN_BITS (secondary); Same data does not override 8.4 '
                            'coding differences. No claim about odd-DTS encoder Pd rounding. A hand-built '
                            'odd parser input uses its supplied Pd, not a required encoder value.'},
 'ST337_LEN_NOPRE': {'doc': 'smpte-st337-2015',
                     'section': '7.2.5',
                     'page': 12,
                     'tier': 'sibling-standard',
                     'quote': 'The size of the burst_preamble words Pa - Pd shall not be counted in the '
                              'value of length_code.',
                     'note': 'Pd counts payload only. Consumer carryover inference: 8.2 shared preamble '
                             'extraction separates Pa-Pd from payload; per-type units still need consumer '
                             'evidence.'},
 'ST337_FIRST_BIT': {'doc': 'smpte-st337-2015',
                     'section': '7.3.1',
                     'page': 12,
                     'tier': 'sibling-standard',
                     'quote': 'the first bit of the first data word of the payload in a burst shall occupy '
                              'the MSB bit position of subframe 1 (time slot 27)',
                     'note': 'Payload is a serial bit stream, first bit in the MSB of the first subframe-1 '
                             'word; consecutive 16-bit words are therefore big-endian over the payload bytes '
                             '(burst structure common to both formats).'},
 'ST337_LAST_UNUSED': {'doc': 'smpte-st337-2015',
                       'section': '7.3.1',
                       'page': 12,
                       'tier': 'sibling-standard',
                       'quote': 'Any unused bits in the last frame shall be set to 0.',
                       'note': 'Bits left over in the last frame of the payload are zero (a lone final byte '
                               'is MSB-aligned; an unused subframe-2 word is 0). Consumer carryover '
                               'inference: unused-bit zeroing is common burst structure under 8.2-8.3. This '
                               'alone does not prove odd-DTS consumer acceptance or Pd rounding; those tests '
                               'are secondary.'},
 'ST337_UNUSED_ZERO': {'doc': 'smpte-st337-2015',
                       'section': '6.1',
                       'page': 6,
                       'tier': 'sibling-standard',
                       'quote': 'Unused bit locations within a sub-frame or in subframes between bursts '
                                'shall be set to',
                       'note': 'Space between bursts (the fill after the payload) is 0.'},
 'ST337_FOUR_ZERO': {'doc': 'smpte-st337-2015',
                     'section': '7.4',
                     'page': 13,
                     'tier': 'sibling-standard',
                     'quote': 'preceded by four AES3-3 subframes which have subframe contents in time slots '
                              '8-27 of all 0s',
                     'note': 'Zero words may precede a burst; they are not part of it (burst offset is the '
                             'index of Pa).'},
 'ST337_IDLE': {'doc': 'smpte-st337-2015',
                'section': 'Annex-A',
                'page': 15,
                'tier': 'sibling-standard',
                'quote': 'Note that if the AES3 stream goes idle (all zeros), the auto-detector will go into '
                         'PCM mode',
                'note': 'An all-zero stream carries no data burst.'},
 'ST338_AC3': {'doc': 'smpte-st338-2016',
               'section': '4',
               'page': 4,
               'tier': 'sibling-standard',
               'quote': '1 AC-3 (audio) data ST 340 Same data',
               'note': "data_type 1 = AC-3; the IEC 61937-2 column (informative) says 'Same data'."},
 'ST338_EAC3_IEC': {'doc': 'smpte-st338-2016',
                    'section': '4',
                    'page': 4,
                    'tier': 'sibling-standard',
                    'quote': 'Enhanced AC-3 / Reserved (depends on',
                    'note': 'Row 21: the IEC 61937-2 allocation is Enhanced AC-3. (Row 16, the professional '
                            "E-AC-3 code, is 'ATRAC-X' in the IEC column, so 16 is not the consumer code.)"},
 'ST338_DTS1': {'doc': 'smpte-st338-2016',
                'section': '4',
                'page': 4,
                'tier': 'sibling-standard',
                'quote': 'ST 2041-2 DTS type I 11 ADTS or LATM/LOAS',
                'note': 'Row 11 (label in the middle line of the wrapped row): IEC allocation DTS type I. '
                        'This row does not establish a sample count; the 512/1024/2048 mapping rests only on '
                        'FF_DTS1/2/3 (secondary).'},
 'ST338_DTS2': {'doc': 'smpte-st338-2016',
                'section': '4',
                'page': 4,
                'tier': 'sibling-standard',
                'quote': '12 Reserved for compatibility with IEC DTS type II',
                'note': 'Row 12: IEC allocation DTS type II. This row does not establish a sample count; the '
                        '512/1024/2048 mapping rests only on FF_DTS1/2/3 (secondary).'},
 'ST338_DTS3': {'doc': 'smpte-st338-2016',
                'section': '4',
                'page': 4,
                'tier': 'sibling-standard',
                'quote': '13 Reserved for compatibility with IEC DTS type III',
                'note': 'Row 13: IEC allocation DTS type III. This row does not establish a sample count; '
                        'the 512/1024/2048 mapping rests only on FF_DTS1/2/3 (secondary).'},
 'ST340_AC3_TYPE': {'doc': 'smpte-st340-2015',
                    'section': '4.2.1',
                    'page': 5,
                    'tier': 'sibling-standard',
                    'quote': 'The data_type identifier shall be set to 1.',
                    'note': 'AC-3 data_type 1 (same code in the IEC 61937-2 column of ST338).'},
 'ST340_AC3_PAYLOAD': {'doc': 'smpte-st340-2015',
                       'section': '4.3',
                       'page': 5,
                       'tier': 'sibling-standard',
                       'quote': 'The Burst Payload of each AC-3 data burst shall contain one complete AC-3 '
                                'Sync Frame.',
                       'note': 'Professional one-syncframe payload. Same data in ST338 suggests consumer '
                               'carryover, but 8.4 permits payload coding differences; FF_PAYLOAD '
                               'independently supports unchanged consumer payload (secondary).'},
 'ST340_AC3_PERIOD': {'doc': 'smpte-st340-2015',
                      'section': '4.6',
                      'page': 6,
                      'tier': 'sibling-standard',
                      'quote': 'AC-3 Burst Payloads occur at the standard Repetition Rate if the Reference '
                               'points for consecutive data bursts (in the same data stream number) occur '
                               '1536 AES3 frames apart.',
                      'note': 'Professional 1536-frame period only; Same data does not establish consumer '
                              'spacing under ST337 8.4. Consumer mapping is secondary FF_AC3_PERIOD; '
                              'A52_DURATION supplies the numeric codec duration missing from the FFmpeg '
                              'macro definition.'},
 'ST340_AC3_PAD': {'doc': 'smpte-st340-2015',
                   'section': '4.1',
                   'page': 4,
                   'tier': 'sibling-standard',
                   'quote': 'enough padding words are appended to it to make the resulting data burst '
                            'duration exactly match that of the 1536 samples of baseband (PCM) audio that it '
                            'represents.',
                   'note': 'Professional padding to 1536 samples only. Consumer carryover is corroboration, '
                           'not normative: 8.4 permits different spacing. Consumer timing rests on '
                           'FF_AC3_PERIOD with A52_DURATION for numeric duration.'},
 'ST340_EAC3_PAYLOAD': {'doc': 'smpte-st340-2015',
                        'section': '5.3',
                        'page': 9,
                        'tier': 'sibling-standard',
                        'quote': 'The E-AC-3 Burst Payload shall contain one or more Sync Frames as shown in '
                                 'Figure 2.',
                        'note': 'Professional syncframe grouping only; 8.4 allows consumer coding '
                                'differences. Tested single-independent-substream consumer concatenation '
                                'rests on FF_EAC3_CONCAT (secondary).'},
 'ST340_EAC3_6BLK': {'doc': 'smpte-st340-2015',
                     'section': '5.3',
                     'page': 10,
                     'tier': 'sibling-standard',
                     'quote': 'deliver six blocks of audio data from all substreams being carried in the '
                              'bitstream.',
                     'note': 'Professional six-block and alignment constraints only. Consumer simple '
                             'fixed-numblkscod groups rest on FF_EAC3_GROUP and FF_EAC3_GROUP_IDX '
                             '(secondary); no consumer convsync or multiple-substream validation asserted.'},
 'ST340_EAC3_TYPE_PRO': {'doc': 'smpte-st340-2015',
                         'section': '5.2.1',
                         'page': 9,
                         'tier': 'sibling-standard',
                         'quote': 'The data_type identifier shall be set to 16.',
                         'note': 'PROFESSIONAL E-AC-3 code; NOT the consumer code (see IEC3_T4 and '
                                 'ST338_EAC3_IEC). Cited so the report can name the conflict; no test '
                                 'expects 16.'},
 'ST340_EAC3_PERIOD_PRO': {'doc': 'smpte-st340-2015',
                           'section': '5.6',
                           'page': 10,
                           'tier': 'sibling-standard',
                           'quote': 'occur at 1536 AES3 frame intervals.',
                           'note': 'PROFESSIONAL E-AC-3 repetition period; the consumer period differs '
                                   '(FFmpeg: 24576 bytes). No test expects 1536 frames for E-AC-3.'},
 'IEC3_T3': {'doc': 'iec61937-3-preview',
             'section': 'front',
             'page': 2,
             'tier': 'primary-preview',
             'quote': 'Data-type-dependent information when data-type bits 0-4 = 1',
             'note': 'Table 3 title: for AC-3, data_type is in bits 0-4 of burst-info and equals 1.'},
 'IEC3_T4': {'doc': 'iec61937-3-preview',
             'section': 'front',
             'page': 2,
             'tier': 'primary-preview',
             'quote': 'data-type bits 0-4 = 21',
             'note': 'Table 4 title: for enhanced AC-3, data_type (bits 0-4) = 21.'},
 'IEC3_T4_56': {'doc': 'iec61937-3-preview',
                'section': 'front',
                'page': 2,
                'tier': 'primary-preview',
                'quote': 'type bits 5-6 = 0',
                'note': 'Table 4 title continues: bits 5-6 of burst-info are 0 for enhanced AC-3.'},
 'IEC3_T5': {'doc': 'iec61937-3-preview',
             'section': 'front',
             'page': 2,
             'tier': 'primary-preview',
             'quote': 'Maximum enhanced AC-3 burst-payload size and bitstream data rate per sampling '
                      'frequency and IEC 60958 frame rate',
             'note': 'Unused title establishes size/rate dependence only. No numerical repetition period or '
                     'difference from 1536 is inferred; table contents absent.'},
 'A52_SYNC': {'doc': 'atsc-a52-2018',
              'section': '5.4.1.1',
              'page': 38,
              'tier': 'codec-spec',
              'quote': 'The syncword is always 0x0B77',
              'note': 'AC-3 numeric syncword only. E-AC-3 numeric support is E_SYNCWORD; E_SYNCINFO provides '
                      'layout only.'},
 'A52_FSCOD': {'doc': 'atsc-a52-2018',
               'section': '5.4.1.3',
               'page': 38,
               'tier': 'codec-spec',
               'quote': '‘00’ 48 ‘01’ 44.1 ‘10’ 32 ‘11’ reserved',
               'note': 'fscod follows crc1 in syncinfo (header layout used by the test frame builder).'},
 'A52_SYNCINFO': {'doc': 'atsc-a52-2018',
                  'section': '5.3.1',
                  'page': 31,
                  'tier': 'codec-spec',
                  'quote': 'syncword 16 crc1 16 fscod 2 frmsizecod 6',
                  'note': 'syncinfo = syncword 16, crc1 16, fscod 2, frmsizecod 6; bsi (bsid 5, bsmod 3, '
                          '...) follows.'},
 'A52_SIZE_48_128': {'doc': 'atsc-a52-2018',
                     'section': '5.4',
                     'page': 52,
                     'tier': 'codec-spec',
                     'quote': '‘010000’ (8) 128 kbps 384 278 256',
                     'note': 'frmsizecod 16/17 at 48 kHz = 256 words (512 bytes).'},
 'A52_SIZE_44_0': {'doc': 'atsc-a52-2018',
                   'section': '5.4',
                   'page': 52,
                   'tier': 'codec-spec',
                   'quote': '‘000000’ (0) 32 kbps 96 69 64',
                   'note': 'frmsizecod 0 at 44.1 kHz = 69 words (odd number of words).'},
 'A52_SIZE_32_40': {'doc': 'atsc-a52-2018',
                    'section': '5.4',
                    'page': 52,
                    'tier': 'codec-spec',
                    'quote': '‘000010’ (1) 40 kbps 120 87 80',
                    'note': 'frmsizecod 2 at 32 kHz = 120 words.'},
 'A52_BSMOD': {'doc': 'atsc-a52-2018',
               'section': '5.3.2',
               'page': 32,
               'tier': 'codec-spec',
               'quote': 'bsid 5 bsmod 3 acmod 3',
               'note': 'bsi: bsid (5 bits) then bsmod (3 bits): byte 5 of an AC-3 syncframe is bsid<<3 | '
                       'bsmod.'},
 'E_SYNCINFO': {'doc': 'etsi-ts-102366',
                'section': 'Annex-E',
                'page': 114,
                'tier': 'codec-spec',
                'quote': 'syncword '
                         '.................................................................................. '
                         '16',
                'note': 'E-AC-3 syncword width and header layout only, not numeric value; E_SYNCWORD '
                        'supplies 0x0B77.'},
 'E_FRMSIZ': {'doc': 'etsi-ts-102366',
              'section': 'Annex-E',
              'page': 127,
              'tier': 'codec-spec',
              'quote': 'The frmsiz field indicates a value one less than the overall size of the coded '
                       'syncframe in 16-bit words.',
              'note': 'E-AC-3 syncframe size = (frmsiz+1) words.'},
 'E_NUMBLKS': {'doc': 'etsi-ts-102366',
               'section': 'Annex-E',
               'page': 127,
               'tier': 'codec-spec',
               'quote': '00 1 block per syncframe 01 2 blocks per syncframe 10 3 blocks per syncframe 11 6 '
                        'blocks per syncframe',
               'note': 'numblkscod 0/1/2/3 = 1/2/3/6 blocks per syncframe (256 samples per block per '
                       'channel).'},
 'DTS_SYNC': {'doc': 'etsi-ts-102114',
              'section': '5.4.2',
              'page': 25,
              'tier': 'codec-spec',
              'quote': 'SYNC = ExtractBits(32); //0x7FFE8001',
              'note': 'A DTS core frame begins with the 32-bit sync word 0x7FFE8001; the header layout '
                      '(FTYPE 1, SHORT 5, CPF 1, NBLKS 7, FSIZE 14) is used by the test frame builder.'},
 'DTS_FSIZE': {'doc': 'etsi-ts-102114',
               'section': '5.4.2',
               'page': 26,
               'tier': 'codec-spec',
               'quote': '(FSIZE+1) is the total byte size of the current frame',
               'note': 'Core frame byte size = FSIZE+1 (the frame may have any byte size in 96..16384, odd '
                       'included).'},
 'DTS_NBLKS': {'doc': 'etsi-ts-102114',
               'section': '5.4.2',
               'page': 26,
               'tier': 'codec-spec',
               'quote': 'The actual core encoding window size is 32 × (NBLKS+1) PCM samples per channel.',
               'note': 'NBLKS 15/31/63 = 512/1024/2048 samples per frame.'},
 'FF_SYNC1': {'doc': 'ffmpeg-spdif-n7.1/spdif',
              'section': 'file',
              'page': 1,
              'tier': 'secondary',
              'quote': '#define SYNCWORD1 0xF872',
              'note': 'FFmpeg Pa.'},
 'FF_SYNC2': {'doc': 'ffmpeg-spdif-n7.1/spdif',
              'section': 'file',
              'page': 1,
              'tier': 'secondary',
              'quote': '#define SYNCWORD2 0x4E1F',
              'note': 'FFmpeg Pb.'},
 'FF_PC_BITS': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                'section': 'file',
                'page': 1,
                'tier': 'secondary',
                'quote': 'data-type (bits 0-6), error flag (bit 7), data-type-dependent info (bits 8-12)',
                'note': 'Consumer type uses bits 0-6, not universally five bits. Tests restrict bits 5-6 to '
                        'zero under ST337_CONSUMER_16 / IEC3_T4_56, so bits 0-4 suffice only in scope. Error '
                        'and dependent-field positions are supported directly.'},
 'FF_PC_STREAM': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                  'section': 'file',
                  'page': 1,
                  'tier': 'secondary',
                  'quote': 'and bitstream number (bits 13-15)',
                  'note': 'Consumer Pc: bitstream number in bits 13-15.'},
 'FF_PD_UNIT': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                'section': 'file',
                'page': 1,
                'tier': 'secondary',
                'quote': 'Pd - length code (number of bits or bytes of encapsuled frame - according to '
                         'data_type)',
                'note': 'The Pd unit depends on the data type (bits for some, bytes for others).'},
 'FF_FILL_ZERO': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                  'section': 'file',
                  'page': 1,
                  'tier': 'secondary',
                  'quote': 'ffio_fill(s->pb, 0, padding);',
                  'note': 'Fill between bursts is zero.'},
 'FF_AC3_TYPE': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                 'section': 'file',
                 'page': 1,
                 'tier': 'secondary',
                 'quote': 'ctx->data_type = IEC61937_AC3 | (bitstream_mode << 8);',
                 'note': 'AC-3 Pc = 0x01 | bsmod<<8 (bsmod in data_type_dependent bits 0-2).'},
 'FF_AC3_BSMOD': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                  'section': 'file',
                  'page': 1,
                  'tier': 'secondary',
                  'quote': 'int bitstream_mode = pkt->data[5] & 0x7;',
                  'note': 'bsmod is the low 3 bits of byte 5 of the AC-3 syncframe.'},
 'FF_AC3_PERIOD': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                   'section': 'file',
                   'page': 1,
                   'tier': 'secondary',
                   'quote': 'ctx->pkt_offset = AC3_FRAME_SIZE << 2;',
                   'note': 'Consumer period mapping to codec frame duration in four-byte interface frames '
                           '(secondary). AC3_FRAME_SIZE definition is absent from supplied FFmpeg files; '
                           'A52_DURATION supplies numeric 1536 codec duration. This macro-to-duration '
                           'inference remains secondary.'},
 'FF_PERIOD_BYTES': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                     'section': 'file',
                     'page': 1,
                     'tier': 'secondary',
                     'quote': 'int pkt_offset; ///< data burst repetition period in bytes',
                     'note': 'pkt_offset is in bytes; one 16-bit word = 2 bytes, one IEC frame = 4 bytes.'},
 'FF_LEN_BITS': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                 'section': 'file',
                 'page': 1,
                 'tier': 'secondary',
                 'quote': 'ctx->length_code = FFALIGN(pkt->size, 2) << 3;',
                 'note': 'Default Pd = payload size in bits (rounded up to whole 16-bit words) for AC-3 and '
                         'DTS.'},
 'FF_EAC3_TYPE': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                  'section': 'file',
                  'page': 1,
                  'tier': 'secondary',
                  'quote': 'ctx->data_type = IEC61937_EAC3;',
                  'note': 'E-AC-3 data_type (0x15 = 21) with no other Pc bits.'},
 'FF_EAC3_ENUM': {'doc': 'ffmpeg-spdif-n7.1/spdif',
                  'section': 'file',
                  'page': 1,
                  'tier': 'secondary',
                  'quote': 'IEC61937_EAC3 = 0x15, ///< E-AC-3 data',
                  'note': '0x15 = 21.'},
 'FF_EAC3_PERIOD': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                    'section': 'file',
                    'page': 1,
                    'tier': 'secondary',
                    'quote': 'ctx->pkt_offset = 24576;',
                    'note': 'E-AC-3 burst period 24576 bytes = 6144 IEC frames = 12288 words.'},
 'FF_EAC3_LEN': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                 'section': 'file',
                 'page': 1,
                 'tier': 'secondary',
                 'quote': 'ctx->length_code = ctx->hd_buf_filled;',
                 'note': 'E-AC-3 Pd = number of payload BYTES (hd_buf_filled counts bytes of the '
                         'concatenated frames).'},
 'FF_EAC3_GROUP': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                   'section': 'file',
                   'page': 1,
                   'tier': 'secondary',
                   'quote': 'static const uint8_t eac3_repeat[4] = {6, 3, 2, 1};',
                   'note': 'Frames per burst indexed by numblkscod.'},
 'FF_EAC3_GROUP_IDX': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                       'section': 'file',
                       'page': 1,
                       'tier': 'secondary',
                       'quote': 'repeat = eac3_repeat[(pkt->data[4] & 0x30) >> 4]; /* numblkscod */',
                       'note': 'numblkscod = bits 5-4 of byte 4 of the E-AC-3 syncframe.'},
 'FF_DTS1': {'doc': 'ffmpeg-spdif-n7.1/spdif',
             'section': 'file',
             'page': 1,
             'tier': 'secondary',
             'quote': 'IEC61937_DTS1 = 0x0B, ///< DTS type I (512 samples)',
             'note': 'Type I = 512-sample frames, data_type 11.'},
 'FF_DTS2': {'doc': 'ffmpeg-spdif-n7.1/spdif',
             'section': 'file',
             'page': 1,
             'tier': 'secondary',
             'quote': 'IEC61937_DTS2 = 0x0C, ///< DTS type II (1024 samples)',
             'note': 'Type II = 1024-sample frames, data_type 12.'},
 'FF_DTS3': {'doc': 'ffmpeg-spdif-n7.1/spdif',
             'section': 'file',
             'page': 1,
             'tier': 'secondary',
             'quote': 'IEC61937_DTS3 = 0x0D, ///< DTS type III (2048 samples)',
             'note': 'Type III = 2048-sample frames, data_type 13.'},
 'FF_DTS_PERIOD': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                   'section': 'file',
                   'page': 1,
                   'tier': 'secondary',
                   'quote': 'ctx->pkt_offset = blocks << 7;',
                   'note': 'DTS burst period in bytes = samples x 4 (blocks = NBLKS+1 is in units of 32 '
                           'samples), i.e. samples frames = 2 x samples words.'},
 'FF_DTS_BADSYNC': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                    'section': 'file',
                    'page': 1,
                    'tier': 'secondary',
                    'quote': 'bad DTS syncword',
                    'note': 'A DTS frame without a core sync word is refused.'},
 'FF_DTS_UNSUPPORTED': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                        'section': 'file',
                        'page': 1,
                        'tier': 'secondary',
                        'quote': 'samples in DTS frame not supported',
                        'note': 'Only 512/1024/2048-sample core frames are carried.'},
 'FF_TOO_BIG': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                'section': 'file',
                'page': 1,
                'tier': 'secondary',
                'quote': 'bitrate is too high',
                'note': 'A payload that does not fit in the repetition period together with the 4 preamble '
                        'words is refused.'},
 'FF_ODD': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
            'section': 'file',
            'page': 1,
            'tier': 'secondary',
            'quote': 'spdif_put_16(ctx, s->pb, ctx->out_buf[ctx->out_bytes - 1] << 8);',
            'note': 'Odd payload: the last byte goes in the high byte of a word.'},
 'E_SYNCWORD': {'doc': 'etsi-ts-102366',
                'section': 'Annex-J',
                'page': 240,
                'quote': 'The syncword parameter shall be 0x0B77, indicating "big endian" byte order.',
                'tier': 'codec-spec',
                'note': 'Explicit numeric syncword for AC-3 / Enhanced AC-3 elementary streams under the '
                        'Annex J constraints used by the fixtures; not consumer carriage evidence.'},
 'FF_EAC3_CONCAT': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                    'section': 'file',
                    'page': 1,
                    'quote': 'memcpy(&ctx->hd_buf[0][ctx->hd_buf_filled], pkt->data, pkt->size);',
                    'tier': 'secondary',
                    'note': 'Consumer E-AC-3 copies successive frame bytes into a concatenated payload '
                            'buffer (secondary).'},
 'FF_PAYLOAD': {'doc': 'ffmpeg-spdif-n7.1/spdifenc',
                'section': 'file',
                'page': 1,
                'quote': 'ctx->out_buf = pkt->data;',
                'tier': 'secondary',
                'note': 'Default output payload is the supplied packet; consumer unchanged AC-3 payload '
                        'support (secondary).'},
 'A52_SIZE_TABLE52': {'doc': 'atsc-a52-2018',
                      'section': '5.4',
                      'page': 52,
                      'quote': '‘000000’ (0)    32 kbps              96                   '
                               '69                   64\n'
                               '‘000001’ (0)    32 kbps              96                   '
                               '70                   64\n'
                               '‘000010’ (1)    40 kbps              120                  '
                               '87                   80\n'
                               '‘000011’ (1)    40 kbps              120                  '
                               '88                   80\n'
                               '‘000100’ (2)    48 kbps              144                  '
                               '104                  96\n'
                               '‘000101’ (2)    48 kbps              144                  '
                               '105                  96\n'
                               '‘000110’ (3)    56 kbps              168                  '
                               '121                  112\n'
                               '‘000111’ (3)    56 kbps              168                  '
                               '122                  112\n'
                               '‘001000’ (4)    64 kbps              192                  '
                               '139                  128\n'
                               '‘001001’ (4)    64 kbps              192                  '
                               '140                  128\n'
                               '‘001010’ (5)    80 kbps              240                  '
                               '174                  160\n'
                               '‘001011’ (5)    80 kbps              240                  '
                               '175                  160\n'
                               '‘001100’ (6)    96 kbps              288                  '
                               '208                  192\n'
                               '‘001101’ (6)    96 kbps              288                  '
                               '209                  192\n'
                               '‘001110’ (7)    112 kbps             336                  '
                               '243                  224\n'
                               '‘001111’ (7)    112 kbps             336                  '
                               '244                  224\n'
                               '‘010000’ (8)    128 kbps             384                  '
                               '278                  256\n'
                               '‘010001’ (8)    128 kbps             384                  '
                               '279                  256\n'
                               '‘010010’ (9)    160 kbps             480                  '
                               '348                  320\n'
                               '‘010011’ (9)    160 kbps             480                  '
                               '349                  320\n'
                               '‘010100’ (10)   192 kbps             576                  '
                               '417                  384\n'
                               '‘010101’ (10)   192 kbps             576                  '
                               '418                  384\n'
                               '‘010110’ (11)   224 kbps             672                  '
                               '487                  448\n'
                               '‘010111’ (11)   224 kbps             672                  '
                               '488                  448\n'
                               '‘011000’ (12)   256 kbps             768                  '
                               '557                  512\n'
                               '‘011001’ (12)   256 kbps             768                  '
                               '558                  512\n'
                               '‘011010’ (13)   320 kbps             960                  '
                               '696                  640\n'
                               '‘011011’ (13)   320 kbps             960                  '
                               '697                  640\n'
                               '‘011100’ (14)   384 kbps             1152                 '
                               '835                  768\n'
                               '‘011101’ (14)   384 kbps             1152                 '
                               '836                  768\n'
                               '‘011110’ (15)   448 kbps             1344                 '
                               '975                  896',
                      'tier': 'codec-spec',
                      'note': 'All literal Table 5.18 rows on this page; columns are 32, 44.1, 48 kHz words '
                              'per syncframe. Used with A52_FSCOD numeric rate-code table.'},
 'A52_SIZE_TABLE53': {'doc': 'atsc-a52-2018',
                      'section': '5.4',
                      'page': 53,
                      'quote': '‘011111’ (15)     448 kbps              1344                  '
                               '976                    896\n'
                               '‘100000’ (16)     512 kbps              1536                  '
                               '1114                   1024\n'
                               '‘100001’ (16)     512 kbps              1536                  '
                               '1115                   1024\n'
                               '‘100010’ (17)     576 kbps              1728                  '
                               '1253                   1152\n'
                               '‘100011’ (17)     576 kbps              1728                  '
                               '1254                   1152\n'
                               '‘100100’ (18)     640 kbps              1920                  '
                               '1393                   1280\n'
                               '‘100101’ (18)     640 kbps              1920                  '
                               '1394                   1280',
                      'tier': 'codec-spec',
                      'note': 'All literal Table 5.18 rows on this page; columns are 32, 44.1, 48 kHz words '
                              'per syncframe. Used with A52_FSCOD numeric rate-code table.'},
 'A52_DURATION': {'doc': 'atsc-a52-2018',
                  'section': '8.2.1.2',
                  'page': 110,
                  'tier': 'codec-spec',
                  'quote': 'each AC-3 syncframe contains 1536 samples of audio per channel.',
                  'note': 'Explicit numeric codec duration, not consumer burst spacing. Together with '
                          'FF_AC3_PERIOD macro-to-frame-duration inference supports secondary consumer '
                          'timing.'}}
