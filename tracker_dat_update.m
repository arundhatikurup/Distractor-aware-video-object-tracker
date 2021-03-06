function [state, location] = tracker_dat_update(state, I, varargin)
  % Configuration parameter
  if nargin < 3
    error('No configuration provided');
  else
    cfg = varargin{1};
  end
  
  %% Resize & preprocess input image
  img_preprocessed = state.imgFunc(imresize(I, state.scale_factor));
  switch cfg.color_space
    case 'rgb'
      img = uint8(255.*img_preprocessed);
    case 'lab'
      img = lab2uint8(applycform(img_preprocessed, state.lab_transform));
    case 'hsv'
      img = uint8(255.*rgb2hsv(img_preprocessed));
    case 'gray'
      img = uint8(255.*rgb2gray(img_preprocessed));
    otherwise
      error('Color space not supported');
  end

  %% Localization
  % Check if we need a refinement
  prev_pos = state.target_pos_history(end,:); % Original image size
  prev_sz = state.target_sz_history(end,:);
  if cfg.motion_estimation_history_size > 0
    prev_pos = prev_pos + getMotionPrediction(state.target_pos_history, cfg.motion_estimation_history_size);
  end
  
  % Previous object location (possibly downscaled)
  target_pos = prev_pos .* state.scale_factor;
  target_sz = prev_sz .* state.scale_factor;
  
  % Search region
  search_sz   = floor(target_sz + cfg.search_win_padding*max(target_sz));
  search_rect = pos2rect(target_pos, search_sz);
  [search_win, padded_search_win] = getSubwindowMasked(img, target_pos, search_sz);
  
  % Apply probability LUT
  pm_search = getForegroundProb(search_win, state.prob_lut, cfg.bin_mapping);
  if cfg.distractor_aware
    pm_search_dist = getForegroundProb(search_win, state.prob_lut_distractor, cfg.bin_mapping);
    pm_search = .5 .* pm_search + .5 .* pm_search_dist;
  end
  pm_search(padded_search_win) = 0;
  
  % Cosine/Hanning window
  cos_win = hann(search_sz(2)) * hann(search_sz(1))';
  
  % Localize
  [hypotheses, vote_scores, dist_scores] = getNMSRects(pm_search, target_sz, cfg.nms_scale,cfg.nms_overlap, cfg.nms_score_factor, cos_win, cfg.nms_include_center_vote);
  candidate_centers = hypotheses(:,1:2) + hypotheses(:,3:4)./2;
  candidate_scores = vote_scores .* dist_scores;
  [~, best_candidate] = max(candidate_scores);
  
  target_pos = candidate_centers(best_candidate,:);


  if size(hypotheses,1) > 1
    idx = 1:size(hypotheses,1);
    idx(best_candidate) = []; % Remove current object location
    distractors = hypotheses(idx,:);
    target_rect = pos2rect(target_pos, target_sz, [size(pm_search,2) size(pm_search,1)]);
    distractor_overlap = intersectionOverUnion(target_rect, distractors);
  else
    distractors = [];
    distractor_overlap = [];
  end
    
  % Localization visualization
  if cfg.show_figures
    figure(2), clf
    imagesc(pm_search,[0 1]);
    axis image
    title('Search Window')
    
    for i = 1:size(hypotheses,1)
      if i == best_candidate, color = 'r'; else color = 'y'; end
      rectangle('Position',hypotheses(i,:),'EdgeColor',color,'LineWidth',2);
    end
  end
    
  
  %% Appearance update
  % Get current target position within full (possibly downscaled) image coordinates
  target_pos_img = target_pos + search_rect(1:2)-1;
  if cfg.prob_lut_update_rate > 0
    % Extract surrounding region
    surr_sz = floor(cfg.surr_win_factor * target_sz);
   % disp('appearance')
    surr_rect = pos2rect(target_pos_img, surr_sz, [size(img,2) size(img,1)]);
   % disp(surr_rect)
    obj_rect_surr = pos2rect(target_pos_img, target_sz, [size(img,2) size(img,1)]) - [surr_rect(1:2)-1, 0, 0];
   % disp(obj_rect_surr)
    surr_win = getSubwindow(img, target_pos_img, surr_sz);
  %  disp (size(surr_win))
    prob_lut_bg = getForegroundBackgroundProbs(surr_win, obj_rect_surr, cfg.num_bins, cfg.bin_mapping);
    
    
    if cfg.distractor_aware
      % Handle distractors
      if size(distractors,1) > 1
        obj_rect = pos2rect(target_pos, target_sz, [size(search_win,2) size(search_win,1)]);
        prob_lut_dist = getForegroundDistractorProbs(search_win, obj_rect, distractors, cfg.num_bins, cfg.bin_mapping);
        state.prob_lut_distractor = (1-cfg.prob_lut_update_rate).*state.prob_lut_distractor + cfg.prob_lut_update_rate .* prob_lut_dist;
      else
        % If there are no distractors, trigger decay of distractor LUT
        state.prob_lut_distractor = (1-cfg.prob_lut_update_rate).*state.prob_lut_distractor + cfg.prob_lut_update_rate .* prob_lut_bg;
      end

      if (isempty(distractors) || all(distractor_overlap < .1)) % Only update if distractors are not overlapping too much
        state.prob_lut = (1-cfg.prob_lut_update_rate) .* state.prob_lut + cfg.prob_lut_update_rate .* prob_lut_bg;
      end
      
      prob_map = getForegroundProb(surr_win, state.prob_lut, cfg.bin_mapping);
      dist_map = getForegroundProb(surr_win, state.prob_lut_distractor, cfg.bin_mapping);
      prob_map = .5.*prob_map + .5.*dist_map;
      
    else % No distractor-awareness
      state.prob_lut = (1-cfg.prob_lut_update_rate) .* state.prob_lut + cfg.prob_lut_update_rate .* prob_lut_bg;
      prob_map = getForegroundProb(surr_win, state.prob_lut, cfg.bin_mapping);
    end
    % Update adaptive threshold  
    state.adaptive_threshold = getAdaptiveThreshold(prob_map, obj_rect_surr, cfg);
    disp ('threshold');
    disp (state.adaptive_threshold);
   
%     t = getAdaptiveThreshold(pm_search, obj_rect_surr, cfg);
%     disp ('threshold 1');
%     disp (t);
  end
  
%     m = size(prob_map,1);
%     %disp (m)
%     n = size(prob_map,2);
%     %disp (n)
%     for i = 1:m
%         for j = 1:n
%             if prob_map(i,j) > 0.6
%                 prob_map(i,j) =1;
%             else
%                 prob_map(i,j) =0;
%             end  
%         end   
%     end
%      

%     binary_prob_map_1=zeros(size(pm_search));
%     [ind]=find(pm_search >= t);
%     binary_prob_map_1(ind)=1;
    %imtool(binary_prob_map_1)

    binary_prob_map=zeros(size(prob_map));
    [ind]=find(prob_map >=state.adaptive_threshold);
    binary_prob_map(ind)=1;
    %imtool(binary_prob_map)
    
%    se = strel('square',3);
%    be=imerode(prob_map,se);
%    % imtool(be);
%    bd=imdilate(be,se);
    
   se = strel('square',3);
   be=imerode(binary_prob_map,se);
   % imtool(be);
   bd=imdilate(be,se);
    
   w1=round(0.8*obj_rect_surr(3));
   h1=round(0.8*obj_rect_surr(4));
   
%    c1=obj_rect_surr(3)/2;
%    c2=obj_rect_surr(3)/2;
   
   cox=round(obj_rect_surr(1)+0.1*obj_rect_surr(3));
   coy=round(obj_rect_surr(2)+0.1*obj_rect_surr(4));
   
   fg_rect=[cox,coy,w1,h1];
   obj_rect=[round(obj_rect_surr(1)),round(obj_rect_surr(2)),round(obj_rect_surr(3)),round(obj_rect_surr(4))];
   
   
    for i=fg_rect(2):fg_rect(2)+fg_rect(4)
        for j=fg_rect(1):fg_rect(1)+fg_rect(3)
            bd(i,j)=1;  
        end
    end
   
    %obj window in surr window
%     figure(2), clf
%     imshow(bd)
%     rectangle('Position',obj_rect, 'EdgeColor', 'g', 'LineWidth', 2);
%     rectangle('Position',fg_rect, 'EdgeColor', 'r', 'LineWidth', 2);
%     drawnow
    
     [L,no]=bwlabel(bd);
     p = L(round(coy+h1/2),round(cox+w1/2));
     [r, c] = find(L==p);
    
    maxr=max(r);
    minr=min(r);
    
    maxc=max(c);
    minc=min(c);
    
    rect =[minc,minr,maxc-minc,maxr-minr];
    
    disp ('Rectangle')
    disp (rect)
    
    %fg after scale adaptation
    figure(4), clf
    imshow(bd)
    rectangle('Position',rect, 'EdgeColor', 'r', 'LineWidth', 2);
    drawnow
    
    %3 rects (plot after prev and all updates
%     figure(5), clf
%     imshow(I)
%     rect_update=[rect(1)+ surr_rect(1),rect(2)+ surr_rect(2),rect(3),rect(4)];
%     rectangle('Position',search_rect, 'EdgeColor', 'y', 'LineWidth', 2);
%     rectangle('Position', surr_rect, 'EdgeColor', 'y', 'LineWidth', 2);
%     rectangle('Position', rect_update, 'EdgeColor', 'y', 'LineWidth', 2);
%     drawnow
    
    %search region
%     figure(6), clf
%     imshow(binary_prob_map_1)
%     rectbw=[rect(1)+ search_rect(1),rect(2)+ search_rect(2),rect(3),rect(4)];
%     rectangle('Position',rectbw, 'EdgeColor', 'r', 'LineWidth', 2);
%     drawnow
    
%     target_pos=[rect(1)+rect(3)/2,rect(2)+rect(4)/2];
%     target_sz=[rect(3),rect(4)];
%       
   % imtool(bd)
   %target_pos=[rect(1)+rect(3)/2 ,rect(2)+rect(4)/2];
   %disp (target_pos);
   
     a=rect(1)+surr_rect(1);
     b=rect(2)+surr_rect(2);
     target_pos=[a+rect(3)/2,b+rect(4)/2];
     target_sz=[rect(3),rect(4)];
    
%      rect_pos=[rect(1)+rect(3)/2,rect(2)+rect(4)/2];
%      target_pos=rect_pos+ surr_rect(1:2)-1;

    
    
  %Store current location
  %target_pos = target_pos + search_rect(1:2)-1;
  target_pos_original = target_pos ./ state.scale_factor;
  target_sz_original = target_sz ./ state.scale_factor;
  
  state.target_pos_history = [state.target_pos_history; target_pos_original];
  state.target_sz_history = [state.target_sz_history; target_sz_original];
  
     scale_change=2;
   
     hyp1=hypot(target_sz_original(1),target_sz_original(2));
     hyp2=hypot(state.target_sz_history(end-1,1), state.target_sz_history(end-1,2));
     s=hyp1/hyp2;
     if(s > scale_change)
       
       location=pos2rect(state.target_pos_history(end-1,:), state.target_sz_history(end-1,:), [size(I,2) size(I,1)]);
     else

       %location=[rect(1)+ surr_rect(1),rect(2)+ surr_rect(2),rect(3),rect(4)];
       location=pos2rect(target_pos_original,target_sz_original, [size(I,2) size(I,1)]);    
        
    end     
    
  
%   move=[rect(1)+ search_rect(1),rect(2)+ search_rect(2),rect(3),rect(4)];
%   
%   figure(7), clf
%   imshow(search_win)
%   rectangle('Position', move, 'EdgeColor', 'b', 'LineWidth', 2);
%   drawnow
%   
%    location=[rect(1)+ search_rect(1),rect(2)+ search_rect(2),rect(3),rect(4)];
%  
%   
  
  if state.report_poly
    location = rect2poly(location);
  end
  
  % Adapt image scale factor
  state.scale_factor = min(1, round(10*cfg.img_scale_target_diagonal/sqrt(sum(target_sz_original.^2)))/10);
%1;
end

function pred = getMotionPrediction(values, maxNumFrames)
  if ~exist('maxNumFrames','var')
    maxNumFrames = 5;
  end
  
  if isempty(values)
    pred = [0,0];
  else
    if size(values,1) < 3
      pred = [0,0];
    else
      maxNumFrames = maxNumFrames + 2;
     
      A1 = 0.8;
      A2 = -1;
      V = values(max(1,end-maxNumFrames):end,:);
      P = zeros(size(V,1)-2, size(V,2));
      for i = 3:size(V,1)
        P(i-2,:) = A1 .* (V(i,:) - V(i-2,:)) + A2 .* (V(i-1,:) - V(i-2,:));
      end
      
      pred = mean(P,1);
    end
  end
end

% target_rect Single 1x4 rect
function iou = intersectionOverUnion(target_rect, candidates)
  assert(size(target_rect,1) == 1)
  inA = rectint(candidates,target_rect);
  unA = prod(target_rect(3:4)) + prod(candidates(:,3:4),2) - inA;
  iou = inA ./ max(eps,unA);
end

